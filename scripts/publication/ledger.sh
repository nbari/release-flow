#!/usr/bin/env bash
# Append-only publication ledger and per-channel publication locks.
#
#   ledger.sh [--uri URI] [--region R] [--endpoint URL] <command> ...
#
#   new-attempt-id
#   record --binding release.json --channel C --attempt ID --seq N --state running|succeeded|failed
#          [--run-url U] [--observed-file F] [--error-class K --error MSG]
#   status --project P --version V [--channel C]
#   lock acquire --project P --version V --channel C --attempt ID [--ttl SECONDS]
#   lock release --project P --version V --channel C --attempt ID
#   lock break   --project P --version V --channel C
#
# Events: ledger/<P>/<V>/<C>/<attempt_id>/<seq4>-<state>.json (create-only).
# status reports per channel the newest succeeded event when any attempt
# succeeded (publication never regresses), else the newest event.
# Locks:  locks/<P>/<V>/<C>.json (create-only; deleted only by their owner or
# by an explicit break after expiry, and only while the stored lock still
# names that attempt: storage.sh delete-lock --attempt).
#
# Exit codes: 0 ok, 1 environment, 2 usage, 3 refused, 4 missing,
# 5 conflict (seq reused), 9 busy (lock held).
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"

usage() {
  sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

storage_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri|--region|--endpoint)
      [[ $# -ge 2 ]] || usage
      storage_args+=("$1" "$2")
      shift 2
      ;;
    -*) usage ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || usage
cmd="$1"
shift

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

st() {
  bash "${RF_SCRIPTS}/storage/storage.sh" ${storage_args[@]+"${storage_args[@]}"} "$@"
}

check_channel() {
  case " ${RF_CHANNELS} " in
    *" $1 "*) ;;
    *) rf_die "ledger: unknown channel: $1" 2 ;;
  esac
}

check_project_version() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || rf_die "ledger: invalid project: $1" 2
  rf_semver_valid "$2" || rf_die "ledger: invalid version: $2" 2
}

new_attempt_id() {
  printf '%s-%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$(rf_random_hex 4)"
}

actor() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_RUN_ID:-}" ]]; then
    printf 'gha:%s/%s' "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT:-1}"
  else
    local u="${USER:-$(id -un 2>/dev/null || echo unknown)}"
    u="$(printf '%s' "${u}" | tr -c 'A-Za-z0-9._@-' '_')"
    printf 'local:%s' "${u:-unknown}"
  fi
}

default_run_url() {
  if [[ "${GITHUB_ACTIONS:-}" == "true" && -n "${GITHUB_RUN_ID:-}" && -n "${GITHUB_REPOSITORY:-}" ]]; then
    printf '%s/%s/actions/runs/%s' "${GITHUB_SERVER_URL:-https://github.com}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}"
  fi
}

# write_event <binding-file> <channel> <attempt> <seq> <state> <run_url> <observed-file|""> <error_class|""> <error|"">
write_event() {
  local binding="$1" channel="$2" attempt="$3" seq="$4" state="$5" run_url="$6" observed="$7" eclass="$8" emsg="$9"
  local project version seq4 prefix existing ev key observed_json='{}'
  project="$(jq -r .project "${binding}")"
  version="$(jq -r .version "${binding}")"
  check_project_version "${project}" "${version}"
  [[ "${seq}" =~ ^[0-9]+$ ]] && (( 10#${seq} >= 1 && 10#${seq} <= 9999 )) || rf_die "ledger: invalid seq: ${seq}" 2
  seq4="$(printf '%04d' "$(( 10#${seq} ))")"
  if [[ -n "${observed}" ]]; then
    observed_json="$(jq -c 'if type == "object" then . else error("observed must be an object") end' "${observed}")" \
      || rf_die "ledger: --observed-file must hold a JSON object" 2
  fi
  prefix="ledger/${project}/${version}/${channel}/${attempt}/"
  existing="$(st list "${prefix}${seq4}-")"
  key="${prefix}${seq4}-${state}.json"
  if [[ -n "${existing}" && "${existing}" != "${key}" ]]; then
    rf_die "ledger: seq ${seq} already recorded for attempt ${attempt} (${existing})" 5
  fi
  ev="${WORK}/event.json"
  jq -n --slurpfile b "${binding}" --arg channel "${channel}" --arg attempt "${attempt}" \
    --argjson seq "$(( 10#${seq} ))" --arg state "${state}" --arg at "$(rf_now_utc)" \
    --arg actor "$(actor)" --arg run_url "${run_url}" --argjson observed "${observed_json}" \
    --arg eclass "${eclass}" --arg emsg "${emsg}" '
    $b[0] as $b |
    {schema_version: 1, kind: "publication-event", project: $b.project, version: $b.version,
     candidate_commit: $b.candidate_commit, manifest_sha256: $b.manifest_sha256, channel: $channel,
     attempt_id: $attempt, seq: $seq, state: $state, at: $at, actor: $actor, run_url: $run_url,
     observed: $observed,
     error_class: (if $eclass == "" then null else $eclass end),
     error: (if $emsg == "" then null else $emsg end)}' > "${ev}"
  st put-record "${key}" "${ev}" --kind publication-event
  rf_kv event "${key}"
}

cmd_record() {
  local binding="" channel="" attempt="" seq="" state="" run_url="" observed="" eclass="" emsg="" emsg_set=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --binding) [[ $# -ge 2 ]] || usage; binding="$2"; shift 2 ;;
      --channel) [[ $# -ge 2 ]] || usage; channel="$2"; shift 2 ;;
      --attempt) [[ $# -ge 2 ]] || usage; attempt="$2"; shift 2 ;;
      --seq) [[ $# -ge 2 ]] || usage; seq="$2"; shift 2 ;;
      --state) [[ $# -ge 2 ]] || usage; state="$2"; shift 2 ;;
      --run-url) [[ $# -ge 2 ]] || usage; run_url="$2"; shift 2 ;;
      --observed-file) [[ $# -ge 2 ]] || usage; observed="$2"; shift 2 ;;
      --error-class) [[ $# -ge 2 ]] || usage; eclass="$2"; shift 2 ;;
      --error) [[ $# -ge 2 ]] || usage; emsg="$2"; emsg_set=true; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "${binding}" && -n "${channel}" && -n "${attempt}" && -n "${seq}" && -n "${state}" ]] || usage
  [[ -f "${binding}" ]] || rf_die "ledger: no such binding file: ${binding}" 2
  check_channel "${channel}"
  if [[ "${state}" == "failed" && ( -z "${eclass}" || "${emsg_set}" != "true" ) ]]; then
    rf_die "ledger: failed events need --error-class and --error" 2
  fi
  [[ -n "${run_url}" ]] || run_url="$(default_run_url)"
  write_event "${binding}" "${channel}" "${attempt}" "${seq}" "${state}" "${run_url}" "${observed}" "${eclass}" "${emsg}"
}

# lock_info <project> <version> <channel> <dest>: 0 present, 4 absent
lock_info() {
  local rc=0
  st get-record "locks/$1/$2/$3.json" "$4" --kind publication-lock 2>/dev/null || rc=$?
  return "${rc}"
}

cmd_status() {
  local project="" version="" only="" keys channel last lockf out ev ch_json channels_json='{}' chans lock_json
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) [[ $# -ge 2 ]] || usage; project="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
      --channel) [[ $# -ge 2 ]] || usage; only="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "${project}" && -n "${version}" ]] || usage
  check_project_version "${project}" "${version}"
  [[ -z "${only}" ]] || check_channel "${only}"
  keys="$(st list "ledger/${project}/${version}/")"
  lock_keys="$(st list "locks/${project}/${version}/")"
  chans="$( { printf '%s\n' "${keys}" | awk -F/ 'NF >= 6 {print $4}'
              printf '%s\n' "${lock_keys}" | awk -F/ 'NF == 4 {sub(/\.json$/, "", $4); print $4}'
              [[ -z "${only}" ]] || printf '%s\n' "${only}"; } | grep -v '^$' | LC_ALL=C sort -u || true)"
  while IFS= read -r channel; do
    [[ -n "${channel}" ]] || continue
    [[ -z "${only}" || "${channel}" == "${only}" ]] || continue
    lock_json="null"
    lockf="${WORK}/lock-${channel}.json"
    if lock_info "${project}" "${version}" "${channel}" "${lockf}"; then
      lock_json="$(jq -c --argjson now "$(rf_now_epoch)" '{attempt_id, expires_at, expired: (.expires_at <= $now)}' "${lockf}")"
    fi
    # Publication is monotonic: once any attempt recorded succeeded, the
    # channel stays succeeded (a later failed retry or a broken lock does not
    # un-publish it); report the newest succeeded event, else the newest event.
    last="$(printf '%s\n' "${keys}" | awk -F/ -v c="${channel}" '$4 == c && $6 ~ /^[0-9]+-succeeded\.json$/' | LC_ALL=C sort | tail -n 1)"
    [[ -n "${last}" ]] || last="$(printf '%s\n' "${keys}" | awk -F/ -v c="${channel}" '$4 == c' | LC_ALL=C sort | tail -n 1)"
    if [[ -n "${last}" ]]; then
      ev="${WORK}/ev-${channel}.json"
      st get-record "${last}" "${ev}" --kind publication-event
      ch_json="$(jq -c --argjson lock "${lock_json}" \
        '{state, attempt_id, seq, at, error_class, error, run_url, lock: $lock}' "${ev}")"
    else
      ch_json="$(jq -nc --argjson lock "${lock_json}" \
        '{state: "pending", attempt_id: null, seq: null, at: null, error_class: null, error: null, run_url: null, lock: $lock}')"
    fi
    channels_json="$(jq -c --arg c "${channel}" --argjson v "${ch_json}" '. + {($c): $v}' <<< "${channels_json}")"
  done <<< "${chans}"
  out="$(jq -n --arg p "${project}" --arg v "${version}" --argjson ch "${channels_json}" \
    '{schema_version: 1, kind: "publication-status", project: $p, version: $v, channels: $ch}')"
  printf '%s\n' "${out}"
}

cmd_lock() {
  local sub="${1:-}" project="" version="" channel="" attempt="" ttl=3600 key rec cur now owner expires
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project) [[ $# -ge 2 ]] || usage; project="$2"; shift 2 ;;
      --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
      --channel) [[ $# -ge 2 ]] || usage; channel="$2"; shift 2 ;;
      --attempt) [[ $# -ge 2 ]] || usage; attempt="$2"; shift 2 ;;
      --ttl) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; ttl="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "${project}" && -n "${version}" && -n "${channel}" ]] || usage
  check_project_version "${project}" "${version}"
  check_channel "${channel}"
  key="locks/${project}/${version}/${channel}.json"
  cur="${WORK}/current-lock.json"
  case "${sub}" in
    acquire)
      [[ -n "${attempt}" ]] || usage
      now="$(rf_now_epoch)"
      rec="${WORK}/lock.json"
      jq -n --arg p "${project}" --arg v "${version}" --arg c "${channel}" --arg a "${attempt}" \
        --argjson now "${now}" --argjson ttl "${ttl}" \
        '{schema_version: 1, kind: "publication-lock", project: $p, version: $v, channel: $c,
          attempt_id: $a, acquired_at: $now, expires_at: ($now + $ttl)}' > "${rec}"
      rf_schema_check publication-lock "${rec}" || rf_die "ledger: invalid lock request" 2
      local rc=0
      st put-record "${key}" "${rec}" --kind publication-lock 2>/dev/null || rc=$?
      if (( rc == 0 )); then
        rf_kv lock acquired
        return 0
      fi
      if (( rc == 5 )) && lock_info "${project}" "${version}" "${channel}" "${cur}"; then
        owner="$(jq -r .attempt_id "${cur}")"
        expires="$(jq -r .expires_at "${cur}")"
        if [[ "${owner}" == "${attempt}" ]]; then
          rf_kv lock acquired
          return 0
        fi
        if (( expires <= now )); then
          rf_log "ledger: ${channel} ${version} is locked by attempt ${owner}, expired at ${expires}; break it with: just release-retry ${version} ${channel} --break-lock"
        else
          rf_log "ledger: ${channel} ${version} is busy: locked by attempt ${owner} until ${expires}"
        fi
        exit 9
      fi
      rf_die "ledger: cannot acquire lock ${key}" 1
      ;;
    release)
      [[ -n "${attempt}" ]] || usage
      local rc=0
      lock_info "${project}" "${version}" "${channel}" "${cur}" || rc=$?
      if (( rc == 4 )); then
        rf_kv lock absent
        return 0
      fi
      (( rc == 0 )) || rf_die "ledger: cannot read lock ${key}" 1
      owner="$(jq -r .attempt_id "${cur}")"
      if [[ "${owner}" != "${attempt}" ]]; then
        rf_die "ledger: refusing to release ${key}: owned by attempt ${owner}, not ${attempt}" 3
      fi
      rc=0
      st delete-lock "${key}" --attempt "${attempt}" || rc=$?
      case "${rc}" in
        0) ;;
        4) rf_kv lock absent; return 0 ;;
        5) rf_die "ledger: refusing to release ${key}: it no longer belongs to attempt ${attempt}" 3 ;;
        *) rf_die "ledger: cannot release ${key}" 1 ;;
      esac
      rf_kv lock released
      ;;
    break)
      local rc=0 binding last_seq seq
      lock_info "${project}" "${version}" "${channel}" "${cur}" || rc=$?
      if (( rc == 4 )); then
        rf_kv lock absent
        return 0
      fi
      (( rc == 0 )) || rf_die "ledger: cannot read lock ${key}" 1
      owner="$(jq -r .attempt_id "${cur}")"
      expires="$(jq -r .expires_at "${cur}")"
      now="$(rf_now_epoch)"
      if (( expires > now )); then
        rf_die "ledger: lock ${key} held by attempt ${owner} has not expired (expires_at ${expires}); refusing to break it" 9
      fi
      binding="${WORK}/binding.json"
      st get-record "releases/${project}/${version}.json" "${binding}" --kind release-binding \
        || rf_die "ledger: cannot break ${key}: release binding releases/${project}/${version}.json is unreadable" 1
      last_seq="$(st list "ledger/${project}/${version}/${channel}/${owner}/" | awk -F/ '{print $NF}' \
        | sed -n 's/^\([0-9]\{4\}\)-.*/\1/p' | LC_ALL=C sort | tail -n 1)"
      seq=$(( 10#${last_seq:-0} + 1 ))
      write_event "${binding}" "${channel}" "${owner}" "${seq}" failed "$(default_run_url)" "" transient "lock broken" >/dev/null
      rc=0
      st delete-lock "${key}" --attempt "${owner}" || rc=$?
      case "${rc}" in
        0|4) ;;
        5) rf_die "ledger: ${key} was taken over while breaking it; not broken" 9 ;;
        *) rf_die "ledger: cannot break ${key}" 1 ;;
      esac
      rf_kv lock broken
      rf_kv attempt_id "${owner}"
      ;;
    *)
      usage
      ;;
  esac
}

case "${cmd}" in
  new-attempt-id) [[ $# -eq 0 ]] || usage; new_attempt_id ;;
  record) cmd_record "$@" ;;
  status) cmd_status "$@" ;;
  lock) cmd_lock "$@" ;;
  *) usage ;;
esac
