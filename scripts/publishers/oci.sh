#!/usr/bin/env bash
# OCI channel (ORAS). Invoked by publication/publish.sh:
#
#   oci.sh observe   prints {"state":"absent|partial|complete|conflict","detail":{...}}
#   oci.sh apply     push by digest, add version tags, move "latest" (exit 0, 1, 4 or 5)
#
# The artifact (publishers.oci.artifact) is an OCI image-layout tarball whose
# index.json holds exactly one manifest: its digest D is what gets published,
# byte for byte. Version tags (publishers.oci.tags) are immutable: a tag that
# points at another digest is a conflict. The optional latest_tag only moves
# forward, through a compare-and-swap pointer in durable storage
# (pointers/<project>/oci/latest.json), and every run repairs the registry
# tag to the pointer, so a late older publisher converges to the newest.
# Inputs (environment): RF_RELEASE_DIR RF_CHANNEL_CONFIG RF_IS_LATEST
# RF_PROJECT RF_VERSION RF_CONFIG_JSON.
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

command -v oras >/dev/null 2>&1 || { echo "oci: missing required tool: oras" >&2; exit 1; }

rc=0
art="$(rf_release_artifact "$(rf_channel_cfg .artifact)")" || rc=$?
(( rc == 0 )) || exit "${rc}"
artifact="${art%%$'\t'*}"
repository="$(rf_tpl "$(rf_channel_cfg .repository)" "${project}" "${version}")"
latest_tag="$(rf_channel_cfg .latest_tag)"
tags=""
while IFS= read -r t; do
  [[ -n "${t}" ]] && tags+="$(rf_tpl "${t}" "${project}" "${version}")"$'\n'
done <<< "$(rf_channel_cfg '.tags[]?')"
manifest_sha="$(jq -r .manifest_sha256 "${RF_RELEASE_DIR}/release.json")"
pointer_key="pointers/${project}/oci/latest.json"

layout="${WORK}/layout"
mkdir -p "${layout}"
if ! tar -xf "${artifact}" -C "${layout}" 2>/dev/null || [[ ! -f "${layout}/index.json" || ! -f "${layout}/oci-layout" ]]; then
  echo "oci: $(basename "${artifact}") is not an OCI image layout tarball" >&2
  exit 5
fi
if [[ "$(jq '.manifests | length' "${layout}/index.json" 2>/dev/null)" != "1" ]]; then
  echo "oci: index.json of $(basename "${artifact}") must hold exactly one manifest" >&2
  exit 5
fi
digest="$(jq -r '.manifests[0].digest' "${layout}/index.json")"
[[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "oci: invalid manifest digest ${digest}" >&2; exit 5; }

# oras_digest <ref>: digest of the reference; 4 when not found
oras_digest() {
  local out
  if out="$(oras manifest fetch --descriptor "$1" 2>"${WORK}/oras.err")"; then
    printf '%s' "${out}" | jq -r .digest
    return 0
  fi
  if grep -qiE 'not ?found|manifest unknown|404' "${WORK}/oras.err"; then
    return 4
  fi
  cat "${WORK}/oras.err" >&2
  return 1
}

# pointer_read: sets PTR_TOKEN (or absent), PTR_VERSION, PTR_DIGEST
pointer_read() {
  local rc=0
  PTR_TOKEN="$(rf_storage head "${pointer_key}" 2>/dev/null)" || rc=$?
  PTR_VERSION=""
  PTR_DIGEST=""
  if (( rc == 4 )); then
    PTR_TOKEN="absent"
    return 0
  fi
  (( rc == 0 )) || return 1
  rc=0
  rf_storage get-record "${pointer_key}" "${WORK}/pointer.json" --kind latest-pointer || rc=$?
  if (( rc == 4 )); then
    PTR_TOKEN="absent"
    return 0
  fi
  (( rc == 0 )) || return 1
  PTR_VERSION="$(jq -r .version "${WORK}/pointer.json")"
  PTR_DIGEST="$(jq -r .digest "${WORK}/pointer.json")"
}

observe() {
  local have_d=false present=0 total=0 conflict="" t d rc needs_latest=false
  rc=0
  oras_digest "${repository}@${digest}" >/dev/null || rc=$?
  case "${rc}" in
    0) have_d=true; present=$(( present + 1 )) ;;
    4) ;;
    *) return 1 ;;
  esac
  while IFS= read -r t; do
    [[ -n "${t}" ]] || continue
    total=$(( total + 1 ))
    rc=0
    d="$(oras_digest "${repository}:${t}")" || rc=$?
    case "${rc}" in
      0)
        if [[ "${d}" == "${digest}" ]]; then
          present=$(( present + 1 ))
        else
          conflict+="${t}=${d} "
        fi
        ;;
      4) ;;
      *) return 1 ;;
    esac
  done <<< "${tags}"
  if [[ -n "${conflict}" ]]; then
    jq -nc --arg r "${repository}" --arg d "${digest}" --arg c "${conflict% }" \
      '{state: "conflict", detail: {repository: $r, digest: $d, reason: "immutable version tags point at another digest", tags: ($c | split(" "))}}'
    return 0
  fi
  if [[ -n "${latest_tag}" ]]; then
    pointer_read || return 1
    if [[ "${RF_IS_LATEST:-false}" == "true" ]] && \
       [[ "${PTR_TOKEN}" == "absent" || "$(rf_semver_cmp "${PTR_VERSION}" "${version}")" == "-1" ]]; then
      needs_latest=true
    fi
    if [[ "${PTR_TOKEN}" != "absent" ]]; then
      rc=0
      d="$(oras_digest "${repository}:${latest_tag}")" || rc=$?
      case "${rc}" in
        0) [[ "${d}" == "${PTR_DIGEST}" ]] || needs_latest=true ;;
        4) needs_latest=true ;;
        *) return 1 ;;
      esac
    fi
  fi
  local state=absent
  if [[ "${have_d}" == "true" && "${present}" -eq $(( total + 1 )) && "${needs_latest}" != "true" ]]; then
    state=complete
  elif (( present > 0 )); then
    state=partial
  fi
  jq -nc --arg s "${state}" --arg r "${repository}" --arg d "${digest}" --argjson latest "${needs_latest}" \
    '{state: $s, detail: {repository: $r, digest: $d, latest_pending: $latest}}'
}

# repair_latest: the registry latest tag follows the stored pointer. The
# pointer is re-read right before and after every re-tag: when it moved
# meanwhile (a newer release took it), the tag is repaired again, so a slow
# repair can never leave latest on an older digest than the pointer.
repair_latest() {
  local d rc i token
  for i in 1 2 3 4 5; do
    pointer_read || return 1
    [[ "${PTR_TOKEN}" != "absent" ]] || return 0
    rc=0
    d="$(oras_digest "${repository}:${latest_tag}")" || rc=$?
    (( rc == 0 || rc == 4 )) || return 1
    if [[ "${rc}" == 0 && "${d}" == "${PTR_DIGEST}" ]]; then
      return 0
    fi
    token="${PTR_TOKEN}"
    pointer_read || return 1
    if [[ "${PTR_TOKEN}" != "${token}" ]]; then
      continue
    fi
    echo "oci: repairing ${repository}:${latest_tag} -> ${PTR_DIGEST} (${PTR_VERSION})" >&2
    oras tag "${repository}@${PTR_DIGEST}" "${latest_tag}" >&2 || return 1
    pointer_read || return 1
    [[ "${PTR_TOKEN}" != "${token}" ]] || return 0
  done
  echo "oci: latest pointer kept changing while repairing ${latest_tag}; giving up after 5 attempts" >&2
  return 1
}

apply() {
  local rc t d i
  rc=0
  oras_digest "${repository}@${digest}" >/dev/null || rc=$?
  if (( rc == 4 )); then
    oras cp --from-oci-layout "${layout}@${digest}" "${repository}@${digest}" >&2 || return 1
  elif (( rc != 0 )); then
    return 1
  fi
  while IFS= read -r t; do
    [[ -n "${t}" ]] || continue
    rc=0
    d="$(oras_digest "${repository}:${t}")" || rc=$?
    if (( rc == 0 )) && [[ "${d}" != "${digest}" ]]; then
      echo "oci: ${repository}:${t} already points at ${d}; version tags are immutable" >&2
      return 5
    fi
    if (( rc == 4 )); then
      oras tag "${repository}@${digest}" "${t}" >&2 || return 1
    elif (( rc != 0 )); then
      return 1
    fi
  done <<< "${tags}"
  [[ -n "${latest_tag}" ]] || return 0
  for i in 1 2 3 4 5; do
    pointer_read || return 1
    if [[ "${RF_IS_LATEST:-false}" != "true" ]]; then
      echo "oci: ${version} is not the latest promoted release; ${latest_tag} is left alone" >&2
      break
    fi
    if [[ "${PTR_TOKEN}" != "absent" && "$(rf_semver_cmp "${PTR_VERSION}" "${version}")" != "-1" ]]; then
      echo "oci: ${latest_tag} pointer already at ${PTR_VERSION}; not moving it back" >&2
      break
    fi
    jq -n --arg p "${project}" --arg v "${version}" --arg d "${digest}" --arg m "${manifest_sha}" \
      '{schema_version: 1, kind: "latest-pointer", project: $p, channel: "oci", version: $v, digest: $d, manifest_sha256: $m}' \
      > "${WORK}/new-pointer.json"
    rf_schema_check latest-pointer "${WORK}/new-pointer.json" || return 1
    rc=0
    rf_storage put-cas "${pointer_key}" "${WORK}/new-pointer.json" --expect "${PTR_TOKEN}" || rc=$?
    if (( rc == 0 )); then
      oras tag "${repository}@${digest}" "${latest_tag}" >&2 || return 1
      break
    fi
    (( rc == 5 )) || return 1
    if (( i == 5 )); then
      echo "oci: latest pointer kept changing; giving up after 5 attempts" >&2
      return 1
    fi
  done
  repair_latest
}

case "${action}" in
  observe) observe ;;
  apply) apply ;;
  *) echo "Usage: oci.sh observe|apply" >&2; exit 2 ;;
esac
