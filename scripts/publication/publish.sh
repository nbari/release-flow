#!/usr/bin/env bash
# Publish one promoted release to one channel, independently of every other
# channel, idempotently and with a durable ledger.
#
#   publish.sh [--project-dir DIR] --version X.Y.Z --channel github-release|oci|crates-io|docs|helm
#
# The publisher code and destinations come from the checkout running this
# script (the current approved code); the release identity comes only from the
# signed tag, and the bytes only from durable storage (resolve.sh). Nothing is
# ever rebuilt, retagged or deleted.
#
# Protocol: resolve -> lock -> ledger "running" -> observe -> (apply ->
# observe) -> ledger "succeeded"|"failed" -> unlock.
#
# stdout: version= channel= state= attempt_id=
# Exit codes: 0 published (or already complete), 1 transient failure,
# 2 usage, 3 identity/policy rejection, 4 source missing (not promoted, or
# blobs expired), 5 conflict with existing published state, 6 integrity
# failure, 7 channel not configured, 9 another attempt holds the channel lock.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"

usage() {
  echo "Usage: publish.sh [--project-dir DIR] --version X.Y.Z --channel github-release|oci|crates-io|docs|helm" >&2
  exit 2
}

project_dir="."
version=""
channel=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    --channel) [[ $# -ge 2 ]] || usage; channel="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "${version}" && -n "${channel}" ]] || usage
rf_semver_valid "${version}" || rf_die "Invalid version: ${version}" 2
case " ${RF_CHANNELS} " in
  *" ${channel} "*) ;;
  *) rf_die "Unknown channel: ${channel} (expected one of: ${RF_CHANNELS})" 2 ;;
esac

top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || rf_die "Not inside a Git work tree: ${project_dir}" 2
cd "${top}"
[[ -f .release-flow.json ]] || rf_die "publish: missing .release-flow.json in ${top}" 3
rf_schema_check config .release-flow.json || rf_die "publish: invalid .release-flow.json" 3
rf_config_load_text "$(cat .release-flow.json)"
channel_cfg="$(printf '%s' "${RF_CONFIG_JSON}" | jq -c --arg c "${channel}" '.publishers[$c] // empty')"
if [[ -z "${channel_cfg}" ]]; then
  echo "publish: channel ${channel} is not configured in .release-flow.json publishers; skipped" >&2
  exit 7
fi
publisher="${RF_SCRIPTS}/publishers/${channel}.sh"
[[ -f "${publisher}" ]] || rf_die "publish: incomplete installation: ${publisher} is missing" 1
project="$(rf_cfg .project)"
uri="$(rf_storage_uri)"
[[ -n "${uri}" ]] || rf_die "publish: storage not configured" 3

ledger() {
  bash "${RF_SCRIPTS}/publication/ledger.sh" --uri "${uri}" --region "$(rf_cfg .storage.region)" \
    --endpoint "$(rf_cfg .storage.endpoint)" "$@"
}

WORK="$(mktemp -d)"
attempt=""
locked=false
seq=0

cleanup() {
  if [[ "${locked}" == "true" ]]; then
    ledger lock release --project "${project}" --version "${version}" --channel "${channel}" --attempt "${attempt}" >/dev/null 2>&1 || \
      echo "publish: could not release the ${channel} lock of attempt ${attempt}" >&2
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

attempt="$(ledger new-attempt-id)"

class_of() {
  case "$1" in
    4) echo missing-source ;;
    5) echo conflict ;;
    6) echo integrity ;;
    3) echo config ;;
    *) echo transient ;;
  esac
}

# event <state> [observed-file] [error-class] [error]
event() {
  local state="$1" observed="${2:-}" eclass="${3:-}" emsg="${4:-}" args
  seq=$(( seq + 1 ))
  args=(record --binding "${WORK}/release/binding.json" --channel "${channel}" --attempt "${attempt}" --seq "${seq}" --state "${state}")
  [[ -z "${observed}" ]] || args+=(--observed-file "${observed}")
  if [[ -n "${eclass}" ]]; then
    args+=(--error-class "${eclass}" --error "${emsg}")
  fi
  ledger "${args[@]}" >/dev/null
}

finish() {
  rf_kv version "${version}"
  rf_kv channel "${channel}"
  rf_kv state "$1"
  rf_kv attempt_id "${attempt}"
}

# 1. Resolve the signed identity and the stored bytes
rc=0
bash "${RF_SCRIPTS}/publication/resolve.sh" --project-dir "${top}" --version "${version}" --out "${WORK}/release" > "${WORK}/resolve.out" || rc=$?
if (( rc != 0 )); then
  if [[ -f "${WORK}/release/binding.json" ]]; then
    msg="resolve failed (exit ${rc})"
    (( rc == 4 )) && msg="source artifacts unavailable in storage; they will not be rebuilt"
    (( rc == 5 )) && msg="stored release binding conflicts with the tag"
    (( rc == 6 )) && msg="stored candidate does not match the signed tag"
    event failed "" "$(class_of "${rc}")" "${msg}" || true
    echo "publish: ${channel} ${version}: ${msg}" >&2
    finish failed
  fi
  exit "${rc}"
fi

# 2. Exclusive per-channel lock, then the running event
lrc=0
ledger lock acquire --project "${project}" --version "${version}" --channel "${channel}" --attempt "${attempt}" >/dev/null || lrc=$?
if (( lrc == 9 )); then
  echo "publish: ${channel} ${version} is being published by another attempt" >&2
  exit 9
fi
(( lrc == 0 )) || rf_die "publish: cannot acquire the ${channel} lock" 1
locked=true
event running

# 3. Publisher inputs
export RF_RELEASE_DIR="${WORK}/release"
export RF_RELEASE_JSON="${WORK}/release/release.json"
export RF_CHANNEL_CONFIG="${channel_cfg}"
export RF_ATTEMPT="${attempt}"
export RF_PROJECT="${project}"
export RF_VERSION="${version}"
export RF_PROJECT_DIR="${top}"
RF_IS_LATEST="$(bash "${RF_SCRIPTS}/publication/latest.sh" --project-dir "${top}" --version "${version}")" || {
  event failed "" transient "cannot decide whether ${version} is the latest release" || true
  finish failed
  exit 1
}
export RF_IS_LATEST

# observe_to <file>: runs `<channel>.sh observe`; returns its exit code
observe_to() {
  local orc=0
  bash "${publisher}" observe > "$1" 2> "${WORK}/observe.err" || orc=$?
  cat "${WORK}/observe.err" >&2
  if (( orc == 0 )) && ! jq -e '(.state | IN("absent","partial","complete","conflict")) and (.detail | type == "object")' "$1" >/dev/null 2>&1; then
    echo "publish: ${channel} observe returned an invalid observation" >&2
    orc=1
  fi
  return "${orc}"
}

fail_with() {
  local code="$1" msg="$2" obs="${3:-}"
  event failed "${obs}" "$(class_of "${code}")" "${msg}" || true
  echo "publish: ${channel} ${version}: ${msg}" >&2
  finish failed
  exit "${code}"
}

# 4. Observe, apply when needed, observe again
orc=0
observe_to "${WORK}/observed-1.json" || orc=$?
(( orc == 0 )) || fail_with "${orc}" "observe failed (exit ${orc}): $(tail -n 1 "${WORK}/observe.err" 2>/dev/null)"
state="$(jq -r .state "${WORK}/observed-1.json")"
case "${state}" in
  complete)
    event succeeded "${WORK}/observed-1.json"
    echo "publish: ${channel} ${version} is already published" >&2
    finish succeeded
    exit 0
    ;;
  conflict)
    fail_with 5 "existing ${channel} state conflicts with ${version}: $(jq -c .detail "${WORK}/observed-1.json")" "${WORK}/observed-1.json"
    ;;
esac

arc=0
bash "${publisher}" apply 2> "${WORK}/apply.err" || arc=$?
cat "${WORK}/apply.err" >&2
if (( arc != 0 )); then
  case "${arc}" in
    4|5|6) ;;
    *) arc=1 ;;
  esac
  fail_with "${arc}" "apply failed (exit ${arc}): $(grep -v '^$' "${WORK}/apply.err" | tail -n 1)"
fi
orc=0
observe_to "${WORK}/observed-2.json" || orc=$?
(( orc == 0 )) || fail_with "${orc}" "observe after apply failed (exit ${orc})"
state="$(jq -r .state "${WORK}/observed-2.json")"
case "${state}" in
  complete)
    event succeeded "${WORK}/observed-2.json"
    echo "publish: ${channel} ${version} published" >&2
    finish succeeded
    ;;
  conflict)
    fail_with 5 "${channel} conflicts after apply: $(jq -c .detail "${WORK}/observed-2.json")" "${WORK}/observed-2.json"
    ;;
  *)
    fail_with 1 "${channel} is still ${state} after apply" "${WORK}/observed-2.json"
    ;;
esac
