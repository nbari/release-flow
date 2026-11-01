#!/usr/bin/env bash
# Read-only release state of one version.
#
#   release-status.sh [--project-dir DIR] <version> [--json]
#
# States: PREPARED (candidate branch, no run) -> VALIDATING -> VALIDATED
# (successful run and a durable candidate record) | VALIDATED_UNRETAINED
# (successful run, no record: not promotable) | VALIDATION_FAILED;
# PROMOTED (signed tag -> C, contained in main and the production base);
# PUBLISHED (PROMOTED and every required channel succeeded; optional channel
# failures never demote); INCONSISTENT (tag exists, but a branch lacks C or the
# tag is not a valid release-flow tag).
#
# Reads only: ls-remote, an object fetch that writes no ref, storage reads and
# gh API reads. Default output is a table on stderr; --json prints
#   {"schema_version":1,"kind":"release-status","project","version","state",
#    "candidate_commit","tag_object","manifest_sha256","binding",
#    "channels":{<ch>:{required,state,attempt_id,at,error_class,error,run_url,lock}}}
# Exit codes: 0 ok, 1 failure, 2 usage, 4 unknown version.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"
# shellcheck source=scripts/lib/github.sh
source "${RF_SCRIPTS}/lib/github.sh"
# shellcheck source=scripts/lib/tag.sh
source "${RF_SCRIPTS}/lib/tag.sh"

usage() {
  echo "Usage: release-status.sh [--project-dir DIR] <version> [--json]" >&2
  exit 2
}

project_dir="."
version=""
json=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --json) json=true; shift ;;
    -*) usage ;;
    *) [[ -z "${version}" ]] || usage; version="$1"; shift ;;
  esac
done
[[ -n "${version}" ]] || usage
rf_semver_valid "${version}" || rf_die "Invalid version: ${version}" 2

top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || rf_die "Not inside a Git work tree: ${project_dir}" 2
cd "${top}"
[[ -f .release-flow.json ]] || rf_die "Missing .release-flow.json in ${top}" 1
rf_schema_check config .release-flow.json || rf_die "Invalid .release-flow.json" 1
rf_config_load_text "$(cat .release-flow.json)"
rf_git_auth_env

project="$(rf_cfg .project)"
repository="$(rf_cfg .repository)"
remote="$(rf_push_remote)"
main_branch="$(rf_cfg .promotion.main_branch)"
[[ -n "${main_branch}" ]] || main_branch="main"
prod_base="$(rf_cfg .production_base)"
mode="$(rf_cfg .promotion.signature_verification)"
[[ -n "${mode}" ]] || mode="github"
workflow="$(rf_cfg .promotion.candidate_workflow)"
[[ -n "${workflow}" ]] || workflow=".github/workflows/candidate.yml"
storage_uri="$(rf_storage_uri)"
publishers="$(printf '%s' "${RF_CONFIG_JSON}" | jq -c '.publishers // {}')"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

ls="$(git ls-remote "${remote}" "refs/tags/${version}" "refs/tags/${version}^{}" "refs/heads/${main_branch}" \
  "refs/heads/${prod_base}" 'refs/heads/release/*')" || rf_die "Cannot query ${remote}" 1
tag_obj="$(rf_ls_remote_value "${ls}" "refs/tags/${version}")"
peeled="$(rf_ls_remote_value "${ls}" "refs/tags/${version}^{}")"
main_sha="$(rf_ls_remote_value "${ls}" "refs/heads/${main_branch}")"
dev_sha="$(rf_ls_remote_value "${ls}" "refs/heads/${prod_base}")"

state=""
detail=""
commit=""
manifest=""
binding=false
channels='{}'

if [[ -n "${tag_obj}" ]]; then
  commit="${peeled:-${tag_obj}}"
  rf_git_fetch "${remote}" "refs/tags/${version}" "refs/heads/${main_branch}" "refs/heads/${prod_base}" \
    || rf_die "Cannot fetch ${version} from ${remote}" 1
  if ! rf_tag_parse "${tag_obj}" > "${WORK}/record.json" 2>"${WORK}/tag.err"; then
    state="INCONSISTENT"
    detail="tag ${version} is not a valid release-flow promotion tag: $(tr '\n' ' ' < "${WORK}/tag.err")"
  elif ! rf_tag_verify_signature "${tag_obj}" "${mode}" "${repository}" "${commit}" "$(rf_cfg .promotion.allowed_signers)" 2>"${WORK}/sig.err"; then
    state="INCONSISTENT"
    detail="tag ${version} signature is not trusted: $(tr '\n' ' ' < "${WORK}/sig.err")"
    manifest="$(jq -r .manifest_sha256 "${WORK}/record.json")"
  else
    manifest="$(jq -r .manifest_sha256 "${WORK}/record.json")"
    if git merge-base --is-ancestor "${commit}" "${main_sha}" 2>/dev/null && \
       git merge-base --is-ancestor "${commit}" "${dev_sha}" 2>/dev/null; then
      state="PROMOTED"
    else
      state="INCONSISTENT"
      detail="${main_branch} or ${prod_base} does not contain ${commit}"
    fi
  fi
  if [[ -n "${storage_uri}" ]]; then
    if rf_storage head "releases/${project}/${version}.json" >/dev/null 2>&1; then
      binding=true
    fi
    status="$(bash "${RF_SCRIPTS}/publication/ledger.sh" --uri "${storage_uri}" --region "$(rf_cfg .storage.region)" \
      --endpoint "$(rf_cfg .storage.endpoint)" status --project "${project}" --version "${version}")" \
      || rf_die "Cannot read the publication ledger" 1
  else
    status='{"channels":{}}'
  fi
  channels="$(jq -nc --argjson p "${publishers}" --argjson s "${status}" '
    $p | to_entries | map({key: .key, value: (
      {required: (.value.required == true)}
      + ($s.channels[.key] // {state: "pending", attempt_id: null, at: null, error_class: null, error: null, run_url: null, lock: null}
         | {state, attempt_id, at, error_class, error, run_url, lock}))}) | from_entries')"
  if [[ "${state}" == "PROMOTED" ]]; then
    state="$(rf_publication_state "$(jq -nc --argjson c "${channels}" '{channels: $c}')" "${publishers}")"
  fi
else
  branches="$(printf '%s\n' "${ls}" | awk '{print $2}' | grep -E "^refs/heads/release/${version//./\\.}-[0-9a-f]{12}$" || true)"
  if [[ -z "${branches}" ]]; then
    rf_die "Unknown version ${version}: no tag and no production candidate branch release/${version}-<base12> on ${remote}" 4
  fi
  branch="$(printf '%s\n' "${branches}" | grep -E -- "-${dev_sha:0:12}$" | head -n 1 || true)"
  [[ -n "${branch}" ]] || branch="$(printf '%s\n' "${branches}" | head -n 1)"
  commit="$(rf_ls_remote_value "${ls}" "${branch}")"
  branch="${branch#refs/heads/}"
  state="PREPARED"
  if command -v gh >/dev/null 2>&1 && [[ -n "${repository}" ]] && \
     runs="$(rf_gh_api "repos/${repository}/actions/workflows/$(basename "${workflow}")/runs?head_sha=${commit}&event=push&per_page=100" 2>/dev/null)"; then
    run="$(printf '%s' "${runs}" | jq -c --arg path "${workflow}" --arg b "${branch}" --arg r "${repository}" '
      [(.workflow_runs // [])[] | select(.path == $path and .event == "push" and .head_branch == $b and .repository.full_name == $r)]
      | if length == 0 then empty else max_by(.run_number) end' 2>/dev/null || true)"
    if [[ -n "${run}" ]]; then
      if [[ "$(printf '%s' "${run}" | jq -r .status)" != "completed" ]]; then
        state="VALIDATING"
      elif [[ "$(printf '%s' "${run}" | jq -r .conclusion)" != "success" ]]; then
        state="VALIDATION_FAILED"
      else
        state="VALIDATED_UNRETAINED"
        if [[ -n "${storage_uri}" ]] && [[ -n "$(rf_storage list "candidates/${project}/${commit}/" 2>/dev/null)" ]]; then
          state="VALIDATED"
        fi
      fi
    fi
  else
    detail="GitHub evidence unavailable (gh missing or unauthenticated)"
  fi
  if [[ -n "${dev_sha}" && "${branch}" != *"-${dev_sha:0:12}" ]]; then
    detail="${detail:+${detail}; }stale: ${prod_base} moved since ${branch} was prepared"
  fi
fi

if [[ "${json}" == "true" ]]; then
  jq -n --arg p "${project}" --arg v "${version}" --arg s "${state}" --arg c "${commit}" --arg t "${tag_obj}" \
    --arg m "${manifest}" --argjson b "${binding}" --argjson ch "${channels}" '
    {schema_version: 1, kind: "release-status", project: $p, version: $v, state: $s,
     candidate_commit: (if $c == "" then null else $c end), tag_object: (if $t == "" then null else $t end),
     manifest_sha256: (if $m == "" then null else $m end), binding: $b, channels: $ch}'
fi
{
  echo "${project} ${version}: ${state}"
  [[ -z "${detail}" ]] || echo "  ${detail}"
  [[ -z "${commit}" ]] || echo "  commit:   ${commit}"
  [[ -z "${tag_obj}" ]] || echo "  tag:      ${tag_obj}"
  [[ -z "${manifest}" ]] || echo "  manifest: ${manifest}"
  if [[ "${channels}" != "{}" ]]; then
    printf '  %-16s %-9s %-10s %-26s %s\n' CHANNEL REQUIRED STATE ATTEMPT ERROR
    printf '%s' "${channels}" | jq -r 'to_entries[] | [.key, (if .value.required then "yes" else "no" end), .value.state,
      (.value.attempt_id // "-"), ((.value.error_class // "") + (if .value.error then ": " + .value.error else "" end))
      + (if .value.lock then " [locked by " + .value.lock.attempt_id + (if .value.lock.expired then ", expired" else "" end) + "]" else "" end)] | @tsv' \
      | while IFS=$'\t' read -r ch req st att err; do
          printf '  %-16s %-9s %-10s %-26s %s\n' "${ch}" "${req}" "${st}" "${att}" "${err}"
        done
  fi
} >&2
