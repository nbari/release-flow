#!/usr/bin/env bash
# crates.io channel. Invoked by publication/publish.sh:
#
#   crates-io.sh observe   prints {"state":"absent|complete|conflict","detail":{...}}
#   crates-io.sh apply     repackage at C, require identical bytes, publish (exit 0, 1, 4 or 5)
#
# Cargo cannot upload a prebuilt .crate, so apply re-runs `cargo package` on
# the exact candidate commit with the cargo version recorded in the manifest
# and publishes only when the result is byte-identical to the validated
# artifact (publishers.crates-io.artifact). Both commands name the package
# (publishers.crates-io.package, default the project), so a workspace with
# several crates publishes exactly that one. Completion is observed in the
# sparse index (publishers.crates-io.index_url, default https://index.crates.io):
# an entry for the version whose cksum equals the artifact digest. A
# non-default index_url is also passed to cargo (--index; http(s) URLs as
# sparse+URL). A publish refused because the version is already uploaded
# (an earlier attempt whose response was lost) is settled by the index.
# Inputs (environment): RF_RELEASE_DIR RF_CHANNEL_CONFIG RF_PROJECT RF_VERSION
# RF_PROJECT_DIR; CARGO_REGISTRY_TOKEN for publishing.
# Tuning: RELEASE_FLOW_CRATES_POLL_TRIES (default 10), RELEASE_FLOW_CRATES_POLL_DELAY (default 6 s).
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

action="${1:-}"
version="${RF_VERSION:?}"
project="${RF_PROJECT:?}"
WORK="$(mktemp -d)"
wt=""
cleanup() {
  if [[ -n "${wt}" && -d "${wt}" ]]; then
    git -C "${RF_PROJECT_DIR}" worktree remove --force "${wt}" 2>/dev/null || rm -rf "${wt}"
    git -C "${RF_PROJECT_DIR}" worktree prune 2>/dev/null || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

rc=0
art="$(rf_release_artifact "$(rf_channel_cfg .artifact)")" || rc=$?
(( rc == 0 )) || exit "${rc}"
crate_sha="${art##*$'\t'}"
package="$(rf_channel_cfg .package)"
[[ -n "${package}" ]] || package="${project}"
index_url="$(rf_channel_cfg .index_url)"
[[ -n "${index_url}" ]] || index_url="https://index.crates.io"
index_url="${index_url%/}"
# cargo arguments: the package, and the registry when it is not crates.io
cargo_args=(--package "${package}")
if [[ "${index_url}" != "https://index.crates.io" ]]; then
  case "${index_url}" in
    http://*|https://*) cargo_args+=(--index "sparse+${index_url}/") ;;
    *) cargo_args+=(--index "${index_url}") ;;
  esac
fi

index_path() {
  local n
  n="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  case "${#n}" in
    1) printf '1/%s' "${n}" ;;
    2) printf '2/%s' "${n}" ;;
    3) printf '3/%s/%s' "${n:0:1}" "${n}" ;;
    *) printf '%s/%s/%s' "${n:0:2}" "${n:2:2}" "${n}" ;;
  esac
}

observe() {
  local url crc=0 entry cksum
  url="${index_url}/$(index_path "${package}")"
  curl -fsS -o "${WORK}/index" "${url}" 2>"${WORK}/curl.err" || crc=$?
  case "${crc}" in
    0) ;;
    22|37) : > "${WORK}/index" ;;
    *) echo "crates-io: cannot read ${url}: $(cat "${WORK}/curl.err")" >&2; return 1 ;;
  esac
  entry="$(jq -c --arg v "${version}" 'select(.vers == $v)' "${WORK}/index" 2>/dev/null | tail -n 1 || true)"
  if [[ -z "${entry}" ]]; then
    jq -nc --arg p "${package}" --arg v "${version}" '{state: "absent", detail: {package: $p, version: $v}}'
    return 0
  fi
  cksum="$(printf '%s' "${entry}" | jq -r .cksum)"
  if [[ "${cksum}" == "${crate_sha}" ]]; then
    jq -nc --arg p "${package}" --arg v "${version}" --arg c "${cksum}" '{state: "complete", detail: {package: $p, version: $v, cksum: $c}}'
  else
    jq -nc --arg p "${package}" --arg v "${version}" --arg c "${cksum}" --arg w "${crate_sha}" \
      '{state: "conflict", detail: {package: $p, version: $v, cksum: $c, expected: $w, reason: "the registry holds different bytes for this version"}}'
  fi
}

apply() {
  local commit tc_ver toolchain=() crate got i state prc=0
  command -v cargo >/dev/null 2>&1 || { echo "crates-io: missing required tool: cargo" >&2; return 1; }
  commit="$(jq -r .candidate_commit "${RF_RELEASE_DIR}/release.json")"
  wt="${WORK}/source"
  git -C "${RF_PROJECT_DIR}" worktree add --detach --quiet "${wt}" "${commit}" || return 1
  if [[ "$(git -C "${wt}" rev-parse HEAD)" != "${commit}" || -n "$(git -C "${wt}" status --porcelain --untracked-files=all)" ]]; then
    echo "crates-io: the source worktree is not a clean checkout of ${commit}" >&2
    return 1
  fi
  tc_ver="$(jq -r '.build_info.tools.cargo // empty' "${RF_RELEASE_DIR}/artifacts/manifest.json" | sed -n 's/^cargo \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [[ -z "${tc_ver}" ]] || toolchain=("+${tc_ver}")
  (cd "${wt}" && cargo ${toolchain[@]+"${toolchain[@]}"} package --locked --no-verify "${cargo_args[@]}" >&2) || return 1
  crate="${wt}/target/package/${package}-${version}.crate"
  [[ -f "${crate}" ]] || { echo "crates-io: cargo package produced no ${package}-${version}.crate" >&2; return 1; }
  got="$(rf_sha256_file "${crate}")"
  if [[ "${got}" != "${crate_sha}" ]]; then
    echo "crates-io: repackaged crate differs from validated bytes (${got} != ${crate_sha}); not publishing" >&2
    return 5
  fi
  (cd "${wt}" && cargo ${toolchain[@]+"${toolchain[@]}"} publish --locked --no-verify "${cargo_args[@]}" > "${WORK}/publish.log" 2>&1) || prc=$?
  cat "${WORK}/publish.log" >&2
  if (( prc != 0 )); then
    if ! grep -qiE 'already (uploaded|exists)' "${WORK}/publish.log"; then
      return 1
    fi
    # an earlier attempt uploaded it (its response was lost): the index decides
    echo "crates-io: ${package} ${version} is already uploaded; checking the index" >&2
  fi
  for i in $(seq 1 "${RELEASE_FLOW_CRATES_POLL_TRIES:-10}"); do
    state="$(observe | jq -r .state)" || state=""
    case "${state}" in
      complete) return 0 ;;
      conflict) return 5 ;;
    esac
    sleep "${RELEASE_FLOW_CRATES_POLL_DELAY:-6}"
  done
  echo "crates-io: ${package} ${version} not visible in ${index_url} yet" >&2
  return 1
}

case "${action}" in
  observe) observe ;;
  apply) apply ;;
  *) echo "Usage: crates-io.sh observe|apply" >&2; exit 2 ;;
esac
