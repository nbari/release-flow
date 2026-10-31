#!/usr/bin/env bash
# git fault-injection shim. Install as `git` first on PATH; it forwards to the
# real git in ${RF_REAL_GIT}. GIT_FAULT selects the fault:
#   push-lost-response   the real (non dry-run) push runs, then the connection
#                        "drops": prints a fatal error and exits 128
#   push-transport-fail  the (non dry-run) push never reaches the remote; exit 128
#   push-lost-unreachable  like push-lost-response, and from then on every
#                        ls-remote fails (one epoch-seconds line per failure in
#                        ${GIT_FAULT_STATE}/git-fault-unreachable.log)
#   push-tag-squatted    before the real (non dry-run) push, another actor
#                        creates the pushed tag as a lightweight tag on the
#                        parent of the pushed commit; the real push then runs
#   push-tag-only        only the tag refspecs of the (non dry-run) push reach
#                        the remote; the push then reports a rejection (exit 1)
#   kill-after-tag       the real tag-creating `git tag` runs, then the whole
#                        process group gets GIT_FAULT_SIGNAL (TERM|KILL, default
#                        TERM); requires STUB_ALLOW_GROUP_KILL=1
#   ls-remote-fail:<n>   the first n ls-remote calls fail (counter in
#                        ${GIT_FAULT_STATE:-${TMPDIR:-/tmp}}/git-fault-ls-remote)
set -uo pipefail

real="${RF_REAL_GIT:?RF_REAL_GIT is required}"
fault="${GIT_FAULT:-}"
state_dir="${GIT_FAULT_STATE:-${TMPDIR:-/tmp}}"

sub=""
dry_run=false
creates_tag=false
skip=0
pre=()
post=()
for arg in "$@"; do
  if (( skip > 0 )); then
    skip=$(( skip - 1 ))
    pre+=("${arg}")
    continue
  fi
  if [[ -z "${sub}" ]]; then
    case "${arg}" in
      -C|-c) skip=1; pre+=("${arg}") ;;
      -*) pre+=("${arg}") ;;
      *) sub="${arg}" ;;
    esac
    continue
  fi
  case "${arg}" in
    --dry-run|-n) dry_run=true ;;
    -s|-a|-m|-F|--sign|--annotate) creates_tag=true ;;
    -*) ;;
    *) post+=("${arg}") ;;
  esac
done

# push_parts: sets push_remote, tag_specs (refs/tags/* refspecs) and
# push_commit (source of the first branch refspec) from the push arguments.
push_parts() {
  local s
  push_remote="${post[0]:-}"
  tag_specs=()
  push_commit=""
  for s in "${post[@]:1}"; do
    case "${s}" in
      refs/tags/*) tag_specs+=("${s}") ;;
      *:refs/heads/*) [[ -n "${push_commit}" ]] || push_commit="${s%%:*}" ;;
    esac
  done
}

if [[ "${sub}" == "ls-remote" && "${fault}" == "push-lost-unreachable" && -f "${state_dir}/git-fault-unreachable" ]]; then
  date +%s >> "${state_dir}/git-fault-unreachable.log"
  echo "fatal: unable to access remote: Could not resolve host (injected)" >&2
  exit 128
fi

case "${fault}:${sub}" in
  push-lost-response:push)
    if [[ "${dry_run}" != "true" ]]; then
      "${real}" "$@" >/dev/null 2>&1
      echo "fatal: the remote end hung up unexpectedly" >&2
      exit 128
    fi
    ;;
  push-transport-fail:push)
    if [[ "${dry_run}" != "true" ]]; then
      echo "fatal: unable to access remote: Could not resolve host" >&2
      exit 128
    fi
    ;;
  kill-after-tag:tag)
    if [[ "${creates_tag}" == "true" ]]; then
      if [[ "${STUB_ALLOW_GROUP_KILL:-}" != "1" ]]; then
        echo "kill-after-tag fault refused without STUB_ALLOW_GROUP_KILL=1" >&2
        exit 2
      fi
      "${real}" "$@"
      kill "-${GIT_FAULT_SIGNAL:-TERM}" 0
      exit 1
    fi
    ;;
  push-lost-unreachable:push)
    if [[ "${dry_run}" != "true" ]]; then
      "${real}" "$@" >/dev/null 2>&1
      mkdir -p "${state_dir}"
      : > "${state_dir}/git-fault-unreachable"
      echo "fatal: the remote end hung up unexpectedly" >&2
      exit 128
    fi
    ;;
  push-tag-squatted:push)
    if [[ "${dry_run}" != "true" ]]; then
      push_parts
      for s in ${tag_specs[@]+"${tag_specs[@]}"}; do
        "${real}" ${pre[@]+"${pre[@]}"} push --quiet "${push_remote}" "${push_commit}^:${s#*:}" >/dev/null 2>&1
      done
    fi
    ;;
  push-tag-only:push)
    if [[ "${dry_run}" != "true" ]]; then
      push_parts
      "${real}" ${pre[@]+"${pre[@]}"} push --quiet "${push_remote}" ${tag_specs[@]+"${tag_specs[@]}"} >/dev/null 2>&1
      echo "error: failed to push some refs (injected: only the tag was accepted)" >&2
      exit 1
    fi
    ;;
  ls-remote-fail:*:ls-remote)
    state="${state_dir}/git-fault-ls-remote"
    n="${fault#ls-remote-fail:}"
    n="${n%%:*}"
    count=$(( $(cat "${state}" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "${count}" > "${state}"
    if (( count <= n )); then
      echo "fatal: unable to access remote (injected ls-remote failure ${count}/${n})" >&2
      exit 128
    fi
    ;;
esac

exec "${real}" "$@"
