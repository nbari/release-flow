#!/usr/bin/env bash
# Helm chart channel: a classic chart repository on a storage URI.
# Invoked by publication/publish.sh:
#
#   helm.sh observe   prints {"state":"absent|partial|complete|conflict","detail":{...}}
#   helm.sh apply     upload the chart create-only, then add it to index.yaml (exit 0, 1, 4 or 5)
#
# Layout under publishers.helm.uri: charts/<name>-<version>.tgz and index.yaml.
# The chart's Chart.yaml version must equal the release version (exit 5).
# index.yaml is written as JSON (valid YAML) and updated by compare-and-swap;
# every update must be a superset of the index it replaces, so concurrent or
# late publishers never drop entries. A non-JSON index is refused (exit 5).
# Inputs (environment): RF_RELEASE_DIR RF_CHANNEL_CONFIG RF_PROJECT RF_VERSION.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

action="${1:-}"
version="${RF_VERSION:?}"
project="${RF_PROJECT:?}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

rc=0
art="$(rf_release_artifact "$(rf_channel_cfg .artifact)")" || rc=$?
(( rc == 0 )) || exit "${rc}"
chart="${art%%$'\t'*}"
chart_sha="${art##*$'\t'}"
repo_uri="$(rf_tpl "$(rf_channel_cfg .uri)" "${project}" "${version}")"
base_url="$(rf_channel_cfg .base_url)"
base_url="${base_url%/}"

helmrepo() {
  bash "${RF_SCRIPTS}/storage/storage.sh" --uri "${repo_uri}" --region "$(rf_cfg .storage.region)" \
    --endpoint "$(rf_cfg .storage.endpoint)" "$@"
}

# Chart metadata from the single top-level <dir>/Chart.yaml
chart_yaml="$(tar -tzf "${chart}" 2>/dev/null | grep -E '^[^/]+/Chart\.yaml$' || true)"
if [[ "$(printf '%s\n' "${chart_yaml}" | grep -c .)" != "1" ]]; then
  echo "helm: $(basename "${chart}") must contain exactly one <chart>/Chart.yaml" >&2
  exit 5
fi
tar -xzOf "${chart}" "${chart_yaml}" > "${WORK}/Chart.yaml"
chart_field() {
  awk -v k="$1" '
    $0 ~ "^" k ":" {
      v = substr($0, length(k) + 2)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "${WORK}/Chart.yaml"
}
c_name="$(chart_field name)"
c_version="$(chart_field version)"
c_api="$(chart_field apiVersion)"
c_app="$(chart_field appVersion)"
c_desc="$(chart_field description)"
if [[ ! "${c_name}" =~ ^[a-z0-9][a-z0-9-]*$ || -z "${c_version}" || -z "${c_api}" ]]; then
  echo "helm: Chart.yaml needs name, version and apiVersion" >&2
  exit 5
fi
if [[ "${c_version}" != "${version}" ]]; then
  echo "helm: Chart.yaml version ${c_version} differs from the release version ${version}; refusing to publish" >&2
  exit 5
fi
chart_file="${c_name}-${c_version}.tgz"
[[ "${chart_file}" =~ ${RF_RE_KEY} ]] || { echo "helm: chart version ${c_version} is not a safe file name" >&2; exit 5; }
chart_key="charts/${chart_file}"
epoch="$(jq -r '.build_info.source_date_epoch' "${RF_RELEASE_DIR}/artifacts/manifest.json")"

# read_index <dest>: 0 present, 4 absent, 5 not JSON, 1 error
read_index() {
  local rc=0
  helmrepo get-object index.yaml "$1" 2>/dev/null || rc=$?
  (( rc == 0 )) || return "${rc}"
  if ! jq -e 'type == "object" and (.entries | type) == "object"' "$1" >/dev/null 2>&1; then
    echo "helm: index.yaml is not a JSON chart index; refusing to rewrite it" >&2
    return 5
  fi
}

# chart_object_state: same|different|absent
chart_object_state() {
  local rc=0
  helmrepo get-object "${chart_key}" "${WORK}/existing.tgz" 2>/dev/null || rc=$?
  if (( rc == 4 )); then echo absent; return 0; fi
  (( rc == 0 )) || return 1
  if [[ "$(rf_sha256_file "${WORK}/existing.tgz")" == "${chart_sha}" ]]; then echo same; else echo different; fi
}

observe() {
  local rc=0 entry_digest="" obj
  read_index "${WORK}/index.json" || rc=$?
  case "${rc}" in
    0) entry_digest="$(jq -r --arg n "${c_name}" --arg v "${c_version}" '[.entries[$n][]? | select(.version == $v) | .digest][0] // empty' "${WORK}/index.json")" ;;
    4) ;;
    5) jq -nc --arg u "${repo_uri}" '{state: "conflict", detail: {uri: $u, reason: "index.yaml is not JSON"}}'; return 0 ;;
    *) return 1 ;;
  esac
  obj="$(chart_object_state)" || return 1
  if [[ "${obj}" == "different" || ( -n "${entry_digest}" && "${entry_digest}" != "${chart_sha}" ) ]]; then
    jq -nc --arg u "${repo_uri}" --arg c "${chart_key}" --arg d "${entry_digest}" \
      '{state: "conflict", detail: {uri: $u, chart: $c, index_digest: $d, reason: "a different chart is published for this version"}}'
  elif [[ "${obj}" == "same" && -n "${entry_digest}" ]]; then
    jq -nc --arg u "${repo_uri}" --arg c "${chart_key}" '{state: "complete", detail: {uri: $u, chart: $c}}'
  elif [[ "${obj}" == "same" || -n "${entry_digest}" ]]; then
    jq -nc --arg u "${repo_uri}" --arg c "${chart_key}" '{state: "partial", detail: {uri: $u, chart: $c}}'
  else
    jq -nc --arg u "${repo_uri}" --arg c "${chart_key}" '{state: "absent", detail: {uri: $u, chart: $c}}'
  fi
}

apply() {
  local rc i token entry
  rc=0
  helmrepo put-object "${chart_key}" "${chart}" || rc=$?
  case "${rc}" in
    0) ;;
    5) echo "helm: ${chart_key} already exists with different content" >&2; return 5 ;;
    *) return 1 ;;
  esac
  entry="$(jq -nc --arg api "${c_api}" --arg n "${c_name}" --arg v "${c_version}" --arg app "${c_app}" \
    --arg desc "${c_desc}" --arg d "${chart_sha}" --argjson e "${epoch}" --arg url "${base_url}/charts/${chart_file}" \
    '{apiVersion: $api, name: $n, version: $v, digest: $d, created: ($e | todate), urls: [$url]}
     + (if $app == "" then {} else {appVersion: $app} end)
     + (if $desc == "" then {} else {description: $desc} end)')"
  for i in 1 2 3 4 5; do
    rc=0
    token="$(helmrepo head index.yaml 2>/dev/null)" || rc=$?
    if (( rc == 4 )); then
      token="absent"
      printf '{"apiVersion":"v1","entries":{}}\n' > "${WORK}/old-index.json"
    elif (( rc == 0 )); then
      rc=0
      read_index "${WORK}/old-index.json" || rc=$?
      (( rc == 0 )) || { (( rc == 5 )) && return 5; continue; }
    else
      return 1
    fi
    existing="$(jq -r --arg n "${c_name}" --arg v "${c_version}" '[.entries[$n][]? | select(.version == $v) | .digest][0] // empty' "${WORK}/old-index.json")"
    if [[ -n "${existing}" ]]; then
      [[ "${existing}" == "${chart_sha}" ]] && return 0
      echo "helm: index.yaml lists ${c_name} ${c_version} with digest ${existing}" >&2
      return 5
    fi
    jq --argjson e "${entry}" '.entries[$e.name] = ((.entries[$e.name] // []) + [$e])' "${WORK}/old-index.json" > "${WORK}/new-index.json"
    if ! jq -e --slurpfile old "${WORK}/old-index.json" '
         . as $new
         | all($old[0].entries | to_entries[]; .key as $k | .value | all(.[]; . as $o
             | any($new.entries[$k][]?; .version == $o.version and .digest == $o.digest)))' "${WORK}/new-index.json" >/dev/null; then
      echo "helm: internal error: the new index would drop entries" >&2
      return 1
    fi
    rc=0
    helmrepo put-cas index.yaml "${WORK}/new-index.json" --expect "${token}" || rc=$?
    (( rc == 0 )) && return 0
    (( rc == 5 )) || return 1
    sleep 0.$(( RANDOM % 5 + 1 ))
  done
  echo "helm: index.yaml kept changing; giving up after 5 attempts" >&2
  return 1
}

case "${action}" in
  observe) observe ;;
  apply) apply ;;
  *) echo "Usage: helm.sh observe|apply" >&2; exit 2 ;;
esac
