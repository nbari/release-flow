#!/usr/bin/env bash
# Durable, content-addressed release storage.
#
#   storage.sh [--uri URI] [--region R] [--endpoint URL] <op> [args...]
#
# Ops:
#   put-blob FILE                         print sha256; identical re-put is a no-op
#   get-blob SHA DEST [--size N]          verified download (never leaves partial files)
#   verify-blob SHA [--size N]
#   put-record KEY FILE --kind K          schema-checked, create-only
#   get-record KEY DEST --kind K
#   put-object KEY FILE | get-object KEY DEST    raw create-only / get
#   head KEY                              print the CAS token
#   put-cas KEY FILE --expect TOKEN|absent
#   list PREFIX                           PREFIX: empty or key segments (no ..)
#   delete-lock KEY --attempt ID          only publication locks under locks/,
#                                         only while owned by attempt ID
#   retain-candidate --dir D --manifest-sha256 M --repository R --run-id RUN
#   materialize --record KEY --out DIR
#
# The URI comes from --uri, else RELEASE_FLOW_STORAGE_URI, else storage.uri in
# the .release-flow.json of the current Git work tree.
#
# Exit codes: 0 ok, 1 environment/transient, 2 usage, 3 policy (not
# configured, test-only candidate), 4 missing, 5 conflict, 6 integrity.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"

usage() {
  sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

uri=""
RF_STORAGE_REGION=""
RF_STORAGE_ENDPOINT=""
uri_given=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri) [[ $# -ge 2 ]] || usage; uri="$2"; uri_given=true; shift 2 ;;
    --region) [[ $# -ge 2 ]] || usage; RF_STORAGE_REGION="$2"; shift 2 ;;
    --endpoint) [[ $# -ge 2 ]] || usage; RF_STORAGE_ENDPOINT="$2"; shift 2 ;;
    -*) usage ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || usage
op="$1"
shift

if [[ -z "${uri}" ]]; then
  if [[ "${uri_given}" != "true" && -n "${RELEASE_FLOW_STORAGE_URI:-}" ]]; then
    uri="${RELEASE_FLOW_STORAGE_URI}"
  elif [[ "${uri_given}" != "true" ]]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "${top}" && -f "${top}/.release-flow.json" ]]; then
      cfg_text="$(cat "${top}/.release-flow.json")"
      if rf_config_load_text "${cfg_text}"; then
        uri="$(rf_cfg '.storage.uri')"
        [[ -n "${RF_STORAGE_REGION}" ]] || RF_STORAGE_REGION="$(rf_cfg '.storage.region')"
        [[ -n "${RF_STORAGE_ENDPOINT}" ]] || RF_STORAGE_ENDPOINT="$(rf_cfg '.storage.endpoint')"
      fi
    fi
  fi
fi
[[ -n "${RF_STORAGE_ENDPOINT}" ]] || RF_STORAGE_ENDPOINT="${AWS_ENDPOINT_URL:-}"
export RF_STORAGE_REGION RF_STORAGE_ENDPOINT

if [[ -z "${uri}" ]]; then
  rf_die "storage not configured: set storage.uri in .release-flow.json or RELEASE_FLOW_STORAGE_URI" 3
fi

case "${uri}" in
  file://*)
    # shellcheck source=scripts/storage/backends/fs.sh
    source "${RF_SCRIPTS}/storage/backends/fs.sh"
    ;;
  s3://*)
    # shellcheck source=scripts/storage/backends/s3.sh
    source "${RF_SCRIPTS}/storage/backends/s3.sh"
    ;;
  *)
    rf_die "storage: unsupported URI scheme: ${uri} (expected file:///abs or s3://bucket/prefix)" 2
    ;;
esac

rf_have_sha256 || rf_die "Missing required tool: sha256sum or shasum" 1
rf_require_tools jq

be_init "${uri}" || exit 1

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

check_key() {
  if [[ ! "$1" =~ ${RF_RE_KEY} ]]; then
    rf_die "storage: invalid key: $1" 2
  fi
}

# check_prefix <prefix>: empty, or a key prefix whose segments are all valid
# key segments (a trailing "/" is allowed); never "..", "." or absolute.
check_prefix() {
  local p="${1%/}"
  [[ -z "$1" ]] && return 0
  if [[ -z "${p}" || ! "${p}" =~ ${RF_RE_KEY} ]]; then
    rf_die "storage: invalid list prefix: $1" 2
  fi
}

check_digest() {
  if [[ ! "$1" =~ ${RF_RE_DIGEST} ]]; then
    rf_die "storage: invalid sha256 digest: $1" 2
  fi
}

blob_key() {
  printf 'blobs/sha256/%s/%s' "${1:0:2}" "$1"
}

# put_raw <key> <file>: create-only; identical existing content is success.
put_raw() {
  local key="$1" file="$2" rc=0 existing
  be_put_create "${key}" "${file}" || rc=$?
  case "${rc}" in
    0) return 0 ;;
    5)
      existing="${WORK}/existing.$$.${RANDOM}"
      be_get "${key}" "${existing}" || return 1
      if cmp -s "${existing}" "${file}"; then
        rm -f "${existing}"
        return 0
      fi
      rm -f "${existing}"
      echo "storage: conflict: ${key} already exists with different content" >&2
      return 5
      ;;
    *) return 1 ;;
  esac
}

# get_blob <sha> <dest> [size]
get_blob() {
  local sha="$1" dest="$2" size="${3:-}" tmp rc=0 actual
  tmp="${dest}.tmp.$$"
  be_get "$(blob_key "${sha}")" "${tmp}" || rc=$?
  if (( rc != 0 )); then
    rm -f "${tmp}"
    if (( rc == 4 )); then
      echo "storage: missing blob sha256:${sha}" >&2
      return 4
    fi
    return 1
  fi
  actual="$(rf_sha256_file "${tmp}")"
  if [[ "${actual}" != "${sha}" ]]; then
    rm -f "${tmp}"
    echo "storage: integrity failure: blob sha256:${sha} has content sha256:${actual}" >&2
    return 6
  fi
  if [[ -n "${size}" && "$(rf_file_size "${tmp}")" != "${size}" ]]; then
    rm -f "${tmp}"
    echo "storage: integrity failure: blob sha256:${sha} size differs from ${size}" >&2
    return 6
  fi
  mv "${tmp}" "${dest}"
}

put_blob() {
  local file="$1" sha rc=0 check
  [[ -f "${file}" ]] || rf_die "storage: no such file: ${file}" 2
  sha="$(rf_sha256_file "${file}")"
  be_put_create "$(blob_key "${sha}")" "${file}" || rc=$?
  case "${rc}" in
    0) ;;
    5)
      check="${WORK}/check.$$"
      rc=0
      get_blob "${sha}" "${check}" || rc=$?
      rm -f "${check}"
      if (( rc == 6 )); then
        echo "storage: corrupt store: existing blob sha256:${sha} does not match its address" >&2
        return 6
      fi
      (( rc == 0 )) || return 1
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${sha}"
}

get_record() {
  local key="$1" dest="$2" kind="$3" tmp rc=0
  tmp="${WORK}/record.$$.${RANDOM}"
  be_get "${key}" "${tmp}" || rc=$?
  if (( rc == 4 )); then
    echo "storage: missing record ${key}" >&2
    return 4
  fi
  (( rc == 0 )) || return 1
  if ! rf_schema_check "${kind}" "${tmp}"; then
    echo "storage: integrity failure: record ${key} is not a valid ${kind}" >&2
    rm -f "${tmp}"
    return 6
  fi
  mv "${tmp}" "${dest}"
}

put_record() {
  local key="$1" file="$2" kind="$3"
  if ! rf_schema_check "${kind}" "${file}"; then
    echo "storage: refusing to write invalid ${kind} record ${key}" >&2
    return 1
  fi
  put_raw "${key}" "${file}"
}

# opt_value <flag> <args...>: value of --flag among args (empty if absent).
parse_kind() {
  local kind=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) [[ $# -ge 2 ]] || usage; kind="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "${kind}" ]] || usage
  printf '%s' "${kind}"
}

retain_candidate() {
  local dir="" pin="" repository="" run_id="" manifest commit mode project version attempt base branch
  local sums_sha rec key name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) [[ $# -ge 2 ]] || usage; dir="$2"; shift 2 ;;
      --manifest-sha256) [[ $# -ge 2 ]] || usage; pin="$2"; shift 2 ;;
      --repository) [[ $# -ge 2 ]] || usage; repository="$2"; shift 2 ;;
      --run-id) [[ $# -ge 2 ]] || usage; run_id="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "${dir}" && -n "${pin}" && -n "${repository}" && -n "${run_id}" ]] || usage
  check_digest "${pin}"
  manifest="${dir}/manifest.json"
  [[ -f "${manifest}" ]] || rf_die "retain-candidate: missing ${manifest}" 6
  commit="$(jq -r '.candidate_commit // empty' "${manifest}" 2>/dev/null || true)"
  [[ "${commit}" =~ ${RF_RE_COMMIT} ]] || rf_die "retain-candidate: manifest has no valid candidate_commit" 6
  if ! bash "${RF_SCRIPTS}/verify-candidate.sh" --dir "${dir}" --commit "${commit}" \
       --repository "${repository}" --run-id "${run_id}" --manifest-sha256 "${pin}" >/dev/null; then
    rf_die "retain-candidate: candidate verification failed; nothing was stored" 6
  fi
  mode="$(jq -r '.mode' "${manifest}")"
  if [[ "${mode}" != "production" ]]; then
    rf_die "retain-candidate: ${mode} candidates are never retained (only production candidates are promotable)" 3
  fi
  project="$(jq -r '.project' "${manifest}")"
  version="$(jq -r '.version' "${manifest}")"
  attempt="$(jq -r '.run_attempt' "${manifest}")"
  base="$(jq -r '.base_commit' "${manifest}")"
  branch="$(jq -r '.candidate_branch' "${manifest}")"
  sums_sha="$(rf_sha256_file "${dir}/SHA256SUMS")"

  rec="${WORK}/candidate-record.json"
  jq -n --arg project "${project}" --arg repository "${repository}" --arg version "${version}" \
    --arg commit "${commit}" --arg base "${base}" --arg branch "${branch}" --arg run_id "${run_id}" \
    --argjson attempt "${attempt}" --arg m "${pin}" --arg s "${sums_sha}" \
    '{schema_version: 1, kind: "candidate-record", project: $project, repository: $repository,
      version: $version, mode: "production", candidate_commit: $commit, base_commit: $base,
      candidate_branch: $branch, run_id: $run_id, run_attempt: $attempt,
      manifest_sha256: $m, sha256sums_sha256: $s}' > "${rec}"
  rf_schema_check candidate-record "${rec}" || rf_die "retain-candidate: manifest identity does not form a valid candidate record" 6

  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    put_blob "${dir}/${name}" >/dev/null
  done <<< "$(jq -r '.artifacts[].name' "${manifest}")"
  put_blob "${manifest}" >/dev/null
  put_blob "${dir}/SHA256SUMS" >/dev/null

  key="candidates/${project}/${commit}/${run_id}-${attempt}.json"
  put_record "${key}" "${rec}" candidate-record
  rf_kv record "${key}"
}

materialize() {
  local key="" out="" rec rc=0 m s name sha size
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --record) [[ $# -ge 2 ]] || usage; key="$2"; shift 2 ;;
      --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ -n "${key}" && -n "${out}" ]] || usage
  check_key "${key}"
  if [[ -e "${out}" && -n "$(ls -A "${out}" 2>/dev/null)" ]]; then
    rf_die "materialize: output directory is not empty: ${out}" 2
  fi
  mkdir -p "${out}"
  rec="${WORK}/materialize-record.json"
  get_record "${key}" "${rec}" candidate-record || return $?
  m="$(jq -r '.manifest_sha256' "${rec}")"
  s="$(jq -r '.sha256sums_sha256' "${rec}")"
  # Artifact names come from stored bytes: check every name before writing
  # anything, so a hostile manifest can never place files outside ${out}.
  get_blob "${m}" "${WORK}/materialize-manifest.json" || return $?
  if ! jq -e '(.artifacts | type) == "array"
        and all(.artifacts[]; (.name | type) == "string"
          and (.name | test("^[A-Za-z0-9][A-Za-z0-9._+-]*$"))
          and .name != "manifest.json" and .name != "SHA256SUMS")
        and ([.artifacts[].name] | length) == ([.artifacts[].name] | unique | length)' \
       "${WORK}/materialize-manifest.json" >/dev/null 2>&1; then
    echo "storage: integrity failure: manifest sha256:${m} holds unsafe or duplicate artifact names; nothing was materialized" >&2
    return 6
  fi
  mv "${WORK}/materialize-manifest.json" "${out}/manifest.json"
  get_blob "${s}" "${out}/SHA256SUMS" || return $?
  while IFS=$'\t' read -r name sha size; do
    [[ -n "${name}" ]] || continue
    rc=0
    get_blob "${sha}" "${out}/${name}" "${size}" || rc=$?
    if (( rc == 4 )); then
      echo "storage: unrecoverable source artifact ${name}: blob sha256:${sha} is missing; it will not be rebuilt" >&2
      return 4
    fi
    (( rc == 0 )) || return "${rc}"
  done <<< "$(jq -r '.artifacts[] | [.name, .sha256, (.size | tostring)] | @tsv' "${out}/manifest.json")"
  if ! bash "${RF_SCRIPTS}/verify-candidate.sh" --dir "${out}" \
       --commit "$(jq -r .candidate_commit "${rec}")" --version "$(jq -r .version "${rec}")" \
       --mode production --base-commit "$(jq -r .base_commit "${rec}")" \
       --project "$(jq -r .project "${rec}")" --repository "$(jq -r .repository "${rec}")" \
       --run-id "$(jq -r .run_id "${rec}")" --manifest-sha256 "${m}" >/dev/null; then
    echo "storage: materialized candidate failed verification" >&2
    return 6
  fi
  if [[ "$(jq -r .run_attempt "${out}/manifest.json")" != "$(jq -r .run_attempt "${rec}")" ]]; then
    echo "storage: integrity failure: manifest run_attempt differs from the candidate record" >&2
    return 6
  fi
}

case "${op}" in
  put-blob)
    [[ $# -eq 1 ]] || usage
    put_blob "$1"
    ;;
  get-blob|verify-blob)
    if [[ "${op}" == "get-blob" ]]; then
      [[ $# -ge 2 ]] || usage
      sha="$1"; dest="$2"; shift 2
    else
      [[ $# -ge 1 ]] || usage
      sha="$1"; dest="${WORK}/verify"; shift
    fi
    size=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --size) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || usage; size="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    check_digest "${sha}"
    get_blob "${sha}" "${dest}" "${size}"
    ;;
  put-record)
    [[ $# -ge 2 ]] || usage
    key="$1"; file="$2"; shift 2
    kind="$(parse_kind "$@")"
    check_key "${key}"
    put_record "${key}" "${file}" "${kind}"
    ;;
  get-record)
    [[ $# -ge 2 ]] || usage
    key="$1"; dest="$2"; shift 2
    kind="$(parse_kind "$@")"
    check_key "${key}"
    get_record "${key}" "${dest}" "${kind}"
    ;;
  put-object)
    [[ $# -eq 2 ]] || usage
    check_key "$1"
    [[ -f "$2" ]] || rf_die "storage: no such file: $2" 2
    put_raw "$1" "$2"
    ;;
  get-object)
    [[ $# -eq 2 ]] || usage
    check_key "$1"
    rc=0
    be_get "$1" "$2.tmp.$$" || rc=$?
    if (( rc != 0 )); then
      rm -f "$2.tmp.$$"
      (( rc == 4 )) && echo "storage: missing object $1" >&2
      exit "${rc}"
    fi
    mv "$2.tmp.$$" "$2"
    ;;
  head)
    [[ $# -eq 1 ]] || usage
    check_key "$1"
    be_head "$1"
    ;;
  put-cas)
    [[ $# -eq 4 && "$3" == "--expect" ]] || usage
    check_key "$1"
    [[ -f "$2" ]] || rf_die "storage: no such file: $2" 2
    be_put_cas "$1" "$2" "$4"
    ;;
  list)
    [[ $# -eq 1 ]] || usage
    check_prefix "$1"
    be_list "$1"
    ;;
  delete-lock)
    [[ $# -eq 3 && "$2" == "--attempt" && -n "$3" ]] || usage
    check_key "$1"
    case "$1" in
      locks/*) ;;
      *) rf_die "storage: delete is only allowed under locks/: $1" 2 ;;
    esac
    rc=0
    token="$(be_head "$1")" || rc=$?
    (( rc == 0 )) || exit "${rc}"
    rc=0
    be_get "$1" "${WORK}/lock.json" || rc=$?
    (( rc == 0 )) || exit "${rc}"
    # the content read above must be the content the token names
    [[ "$(be_head "$1" 2>/dev/null || true)" == "${token}" ]] \
      || rf_die "storage: ${1} changed while being read; not deleted" 5
    rf_schema_check publication-lock "${WORK}/lock.json" \
      || rf_die "storage: integrity failure: ${1} is not a valid publication-lock; not deleted" 6
    owner="$(jq -r .attempt_id "${WORK}/lock.json")"
    [[ "${owner}" == "$3" ]] || rf_die "storage: ${1} is owned by attempt ${owner}, not $3; not deleted" 5
    rc=0
    be_delete_if "$1" "${token}" || rc=$?
    case "${rc}" in
      0) ;;
      5) rf_die "storage: ${1} changed before it could be deleted; not deleted" 5 ;;
      *) exit "${rc}" ;;
    esac
    ;;
  retain-candidate)
    retain_candidate "$@"
    ;;
  materialize)
    materialize "$@"
    ;;
  *)
    usage
    ;;
esac
