#!/usr/bin/env bash
# Documentation channel: a versioned static site on a storage URI.
# Invoked by publication/publish.sh:
#
#   docs.sh observe   prints {"state":"absent|partial|complete|conflict","detail":{...}}
#   docs.sh apply     upload <V>/<path> create-only, then the marker (exit 0, 1, 4 or 5)
#
# Layout under publishers.docs.uri (a file:/// or s3:// storage URI template):
#   <V>/<path>                   the files of the docs tarball (never overwritten)
#   release-flow/<V>.json        marker (docs-marker) written last: complete
#   latest.json                  latest-pointer, moved forward only, by CAS
#                                (publishers.docs.latest)
# The tarball may hold only regular files and directories with relative,
# storage-safe paths; anything else is refused before any write.
# Inputs (environment): RF_RELEASE_DIR RF_CHANNEL_CONFIG RF_IS_LATEST
# RF_PROJECT RF_VERSION.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"

action="${1:-}"
version="${RF_VERSION:?}"
project="${RF_PROJECT:?}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

rc=0
art="$(rf_release_artifact "$(rf_channel_cfg .artifact)")" || rc=$?
(( rc == 0 )) || exit "${rc}"
artifact="${art%%$'\t'*}"
artifact_sha="${art##*$'\t'}"
docs_uri="$(rf_tpl "$(rf_channel_cfg .uri)" "${project}" "${version}")"
want_latest="$(rf_channel_cfg .latest)"
manifest_sha="$(jq -r .manifest_sha256 "${RF_RELEASE_DIR}/release.json")"
marker_key="release-flow/${version}.json"

docs() {
  bash "${RF_SCRIPTS}/storage/storage.sh" --uri "${docs_uri}" --region "$(rf_cfg .storage.region)" \
    --endpoint "$(rf_cfg .storage.endpoint)" "$@"
}

# validate: prints the sorted file list; exit 5 on unsafe content
validate() {
  local names types n t count=0
  names="$(tar -tzf "${artifact}" 2>/dev/null)" || { echo "docs: $(basename "${artifact}") is not a gzip tarball" >&2; return 5; }
  types="$(tar -tvzf "${artifact}" 2>/dev/null | cut -c1)"
  if printf '%s\n' "${types}" | grep -qv '^[-d]$'; then
    echo "docs: tarball holds entries that are neither regular files nor directories (links, devices)" >&2
    return 5
  fi
  : > "${WORK}/files"
  while IFS=$'\t' read -r t n; do
    [[ -n "${n}" ]] || continue
    n="${n#./}"
    [[ -n "${n}" ]] || continue
    case "/${n}/" in
      //*|*/../*|*/./*)
        echo "docs: unsafe path in tarball: ${n}" >&2
        return 5
        ;;
    esac
    if [[ "${t}" == "d" ]]; then
      continue
    fi
    if [[ ! "${n}" =~ ${RF_RE_KEY} ]]; then
      echo "docs: path not allowed in a docs site: ${n}" >&2
      return 5
    fi
    printf '%s\n' "${n}" >> "${WORK}/files"
    count=$(( count + 1 ))
  done <<< "$(paste <(printf '%s\n' "${types}") <(printf '%s\n' "${names}"))"
  (( count > 0 )) || { echo "docs: tarball holds no files" >&2; return 5; }
  LC_ALL=C sort -o "${WORK}/files" "${WORK}/files"
}

expected_marker() {
  jq -n --arg p "${project}" --arg v "${version}" --arg m "${manifest_sha}" --arg a "${artifact_sha}" \
    --argjson n "$(wc -l < "${WORK}/files" | tr -d ' ')" \
    '{schema_version: 1, kind: "docs-marker", project: $p, version: $v, manifest_sha256: $m, artifact_sha256: $a, files: $n}' > "$1"
}

# latest_pending: re-reads latest.json; 0 when it should move to this version
# (LATEST_TOKEN then holds its CAS token, or "absent"), 1 when not, 2 when it
# cannot be read. The token is read before the record, so a concurrent move
# can only make the token stale (and the CAS fail), never pair an older
# version with a newer token.
latest_pending() {
  local rc=0
  [[ "${want_latest}" == "true" && "${RF_IS_LATEST:-false}" == "true" ]] || return 1
  LATEST_TOKEN="$(docs head latest.json 2>/dev/null)" || rc=$?
  if (( rc == 4 )); then LATEST_TOKEN="absent"; return 0; fi
  (( rc == 0 )) || return 2
  docs get-record latest.json "${WORK}/latest.json" --kind latest-pointer 2>/dev/null || rc=$?
  (( rc == 0 )) || return 2
  [[ "$(rf_semver_cmp "$(jq -r .version "${WORK}/latest.json")" "${version}")" == "-1" ]]
}

observe() {
  local rc=0 existing
  validate || return $?
  expected_marker "${WORK}/marker.json"
  docs get-record "${marker_key}" "${WORK}/have-marker.json" --kind docs-marker 2>/dev/null || rc=$?
  if (( rc == 0 )); then
    if [[ "$(jq -cS . "${WORK}/have-marker.json")" != "$(jq -cS . "${WORK}/marker.json")" ]]; then
      jq -nc --arg u "${docs_uri}" --slurpfile have "${WORK}/have-marker.json" \
        '{state: "conflict", detail: {uri: $u, reason: "a different docs build is published for this version", marker: $have[0]}}'
    else
      rc=0
      latest_pending || rc=$?
      case "${rc}" in
        0) jq -nc --arg u "${docs_uri}" '{state: "partial", detail: {uri: $u, latest_pending: true}}' ;;
        1) jq -nc --arg u "${docs_uri}" '{state: "complete", detail: {uri: $u}}' ;;
        *) echo "docs: cannot read latest.json" >&2; return 1 ;;
      esac
    fi
    return 0
  fi
  (( rc == 4 )) || return 1
  existing="$(docs list "${version}/")" || return 1
  if [[ -n "${existing}" ]]; then
    jq -nc --arg u "${docs_uri}" --argjson n "$(printf '%s\n' "${existing}" | grep -c .)" '{state: "partial", detail: {uri: $u, files_present: $n}}'
  else
    jq -nc --arg u "${docs_uri}" '{state: "absent", detail: {uri: $u}}'
  fi
}

apply() {
  local f rc i
  validate || return $?
  mkdir -p "${WORK}/site"
  tar -xzf "${artifact}" -C "${WORK}/site"
  while IFS= read -r f; do
    [[ -n "${f}" ]] || continue
    rc=0
    docs put-object "${version}/${f}" "${WORK}/site/${f}" || rc=$?
    case "${rc}" in
      0) ;;
      5) echo "docs: ${version}/${f} already exists with different content" >&2; return 5 ;;
      *) return 1 ;;
    esac
  done < "${WORK}/files"
  expected_marker "${WORK}/marker.json"
  rc=0
  docs put-record "${marker_key}" "${WORK}/marker.json" --kind docs-marker || rc=$?
  case "${rc}" in
    0) ;;
    5) return 5 ;;
    *) return 1 ;;
  esac
  # Each round re-reads the pointer and its token right before the CAS, so a
  # newer version written meanwhile is seen and never overwritten.
  for i in 1 2 3 4 5; do
    rc=0
    latest_pending || rc=$?
    case "${rc}" in
      0) ;;
      1) return 0 ;;
      *) echo "docs: cannot read latest.json" >&2; return 1 ;;
    esac
    jq -n --arg p "${project}" --arg v "${version}" --arg d "${artifact_sha}" --arg m "${manifest_sha}" \
      '{schema_version: 1, kind: "latest-pointer", project: $p, channel: "docs", version: $v, digest: $d, manifest_sha256: $m}' \
      > "${WORK}/new-latest.json"
    rc=0
    docs put-cas latest.json "${WORK}/new-latest.json" --expect "${LATEST_TOKEN}" || rc=$?
    (( rc == 0 )) && return 0
    (( rc == 5 )) || return 1
    sleep 0.$(( RANDOM % 5 + 1 ))
  done
  echo "docs: latest.json kept changing; giving up after 5 attempts" >&2
  return 1
}

case "${action}" in
  observe) observe ;;
  apply) apply ;;
  *) echo "Usage: docs.sh observe|apply" >&2; exit 2 ;;
esac
