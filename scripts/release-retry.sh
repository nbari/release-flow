#!/usr/bin/env bash
# Re-run one publication channel of a promoted release, with current approved
# publisher code, against the same signed tag and the same stored bytes.
#
#   release-retry.sh [--project-dir DIR] <version> <channel> [--local] [--ref REF] [--break-lock]
#
#   (default)     dispatch release.yml on --ref (default promotion.publisher_ref,
#                 else main) for this version and channel
#   --local       run scripts/publication/publish.sh from this checkout instead
#   --break-lock  first break the channel's publication lock, only if it expired
#
# Never retags, never rebuilds, never touches other channels.
# stdout: version= channel= mode=local|dispatched state= run_url=
# Exit codes: 0 ok, 1 failure, 2 usage or channel not configured, 4 version not
# promoted; with --local, the publish.sh exit code (5 conflict, 6 integrity,
# 9 busy, ...).
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"

usage() {
  echo "Usage: release-retry.sh [--project-dir DIR] <version> <channel> [--local] [--ref REF] [--break-lock]" >&2
  exit 2
}

project_dir="."
version=""
channel=""
local_run=false
ref=""
break_lock=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --local) local_run=true; shift ;;
    --ref) [[ $# -ge 2 ]] || usage; ref="$2"; shift 2 ;;
    --break-lock) break_lock=true; shift ;;
    -*) usage ;;
    *)
      if [[ -z "${version}" ]]; then version="$1"
      elif [[ -z "${channel}" ]]; then channel="$1"
      else usage
      fi
      shift
      ;;
  esac
done
[[ -n "${version}" && -n "${channel}" ]] || usage
rf_semver_valid "${version}" || rf_die "Invalid version: ${version}" 2
[[ "${local_run}" != "true" || -z "${ref}" ]] || rf_die "--ref applies only to dispatched retries" 2

top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || rf_die "Not inside a Git work tree: ${project_dir}" 2
cd "${top}"
[[ -f .release-flow.json ]] || rf_die "Missing .release-flow.json in ${top}" 1
rf_schema_check config .release-flow.json || rf_die "Invalid .release-flow.json" 1
rf_config_load_text "$(cat .release-flow.json)"
rf_git_auth_env

if [[ -z "$(printf '%s' "${RF_CONFIG_JSON}" | jq -c --arg c "${channel}" '.publishers[$c] // empty')" ]]; then
  rf_die "Channel '${channel}' is not configured in .release-flow.json publishers (configured: $(printf '%s' "${RF_CONFIG_JSON}" | jq -r '.publishers // {} | keys | join(", ")'))" 2
fi
project="$(rf_cfg .project)"
repository="$(rf_cfg .repository)"
remote="$(rf_push_remote)"

if ! tag="$(git ls-remote "${remote}" "refs/tags/${version}")"; then
  rf_die "Cannot query ${remote}" 1
fi
[[ -n "${tag}" ]] || rf_die "${version} is not promoted (no tag ${version} on ${remote}); nothing to retry" 4

if [[ "${break_lock}" == "true" ]]; then
  uri="$(rf_storage_uri)"
  [[ -n "${uri}" ]] || rf_die "storage not configured" 1
  rc=0
  bash "${RF_SCRIPTS}/publication/ledger.sh" --uri "${uri}" --region "$(rf_cfg .storage.region)" \
    --endpoint "$(rf_cfg .storage.endpoint)" lock break --project "${project}" --version "${version}" \
    --channel "${channel}" >&2 || rc=$?
  (( rc == 0 )) || rf_die "Cannot break the ${channel} lock of ${version} (exit ${rc})" "${rc}"
fi

if [[ "${local_run}" == "true" ]]; then
  rc=0
  out="$(bash "${RF_SCRIPTS}/publication/publish.sh" --project-dir "${top}" --version "${version}" --channel "${channel}")" || rc=$?
  state="$(printf '%s\n' "${out}" | sed -n 's/^state=//p')"
  rf_kv version "${version}"
  rf_kv channel "${channel}"
  rf_kv mode local
  rf_kv state "${state:-failed}"
  rf_kv run_url ""
  exit "${rc}"
fi

[[ -n "${repository}" ]] || rf_die ".release-flow.json lacks \"repository\" (needed to dispatch release.yml)" 1
command -v gh >/dev/null 2>&1 || rf_die "Missing required tool: gh (or use --local)" 1
if [[ -z "${ref}" ]]; then
  ref="$(rf_cfg .promotion.publisher_ref)"
  [[ -n "${ref}" ]] || ref="main"
fi
if ! gh workflow run release.yml --repo "${repository}" --ref "${ref}" -f "version=${version}" -f "channel=${channel}" >&2; then
  rf_die "Cannot dispatch release.yml on ${ref}. release.yml must exist on the default branch; until then use --local." 1
fi
rf_kv version "${version}"
rf_kv channel "${channel}"
rf_kv mode dispatched
rf_kv state dispatched
rf_kv run_url "https://github.com/${repository}/actions/workflows/release.yml"
echo "Dispatched release.yml (${channel}) for ${version} on ${ref}; follow it with: just release-status ${version}" >&2
