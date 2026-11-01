# shellcheck shell=bash
# S3 storage backend (s3://bucket/prefix) over the aws CLI. Sourced by
# storage.sh. Create-only writes use If-None-Match: *, compare-and-swap and
# lock deletion use If-Match: <etag>. Providers that ignore conditional
# headers are unsupported.
# bash 3.2 compatible.

BE_BUCKET=""
BE_PREFIX=""
BE_ARGS=()

be_init() {
  local uri="$1" rest help_text
  rest="${uri#s3://}"
  BE_BUCKET="${rest%%/*}"
  if [[ "${rest}" == */* ]]; then BE_PREFIX="${rest#*/}"; else BE_PREFIX=""; fi
  BE_PREFIX="${BE_PREFIX%/}"
  if [[ ! "${BE_BUCKET}" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
    echo "storage: invalid S3 bucket in ${uri}" >&2
    return 1
  fi
  if [[ -n "${BE_PREFIX}" && ! "${BE_PREFIX}" =~ ${RF_RE_KEY} ]]; then
    echo "storage: invalid S3 prefix in ${uri}" >&2
    return 1
  fi
  command -v aws >/dev/null 2>&1 || { echo "storage: Missing required tool: aws" >&2; return 1; }
  BE_ARGS=(--output json)
  if [[ -n "${RF_STORAGE_ENDPOINT:-}" ]]; then
    BE_ARGS+=(--endpoint-url "${RF_STORAGE_ENDPOINT}")
  fi
  if [[ -n "${RF_STORAGE_REGION:-}" ]]; then
    BE_ARGS+=(--region "${RF_STORAGE_REGION}")
  fi
  help_text="$(AWS_PAGER="" aws s3api put-object help 2>/dev/null | cat || true)"
  case "${help_text}" in
    *--if-none-match*) ;;
    *)
      echo "storage: conditional writes unsupported by the installed aws CLI (put-object lacks --if-none-match); upgrade aws-cli" >&2
      return 1
      ;;
  esac
}

be_key() {
  if [[ -n "${BE_PREFIX}" ]]; then printf '%s/%s' "${BE_PREFIX}" "$1"; else printf '%s' "$1"; fi
}

# be_aws <stderr-file> <args...>: aws s3api with the configured endpoint/region.
be_aws() {
  local errf="$1"
  shift
  AWS_PAGER="" aws s3api "$@" "${BE_ARGS[@]}" 2> "${errf}"
}

be_missing() {
  grep -qE 'NoSuchKey|\(404\)|Not Found' "$1"
}

be_precondition() {
  grep -qE 'PreconditionFailed|\(412\)' "$1"
}

be_b64_sha256() {
  local hex
  hex="$(rf_sha256_file "$1")"
  # shellcheck disable=SC2059
  printf "$(printf '%s' "${hex}" | sed 's/../\\x&/g')" | base64 | tr -d '\n'
}

be_head() {
  local errf out rc
  errf="$(mktemp)"
  if out="$(be_aws "${errf}" head-object --bucket "${BE_BUCKET}" --key "$(be_key "$1")")"; then
    rm -f "${errf}"
    printf '%s' "${out}" | jq -r '.ETag' | tr -d '"'
    return 0
  fi
  if be_missing "${errf}"; then rc=4; else cat "${errf}" >&2; rc=1; fi
  rm -f "${errf}"
  return "${rc}"
}

be_get() {
  local errf rc
  errf="$(mktemp)"
  if be_aws "${errf}" get-object --bucket "${BE_BUCKET}" --key "$(be_key "$1")" "$2" >/dev/null; then
    rm -f "${errf}"
    return 0
  fi
  if be_missing "${errf}"; then rc=4; else cat "${errf}" >&2; rc=1; fi
  rm -f "${errf}"
  return "${rc}"
}

# be_put_cond <key> <src> <condition-flag> <condition-value>
be_put_cond() {
  local key="$1" src="$2" flag="$3" value="$4" errf sum attempt=0 rc
  sum="$(be_b64_sha256 "${src}")"
  errf="$(mktemp)"
  while :; do
    attempt=$(( attempt + 1 ))
    if be_aws "${errf}" put-object --bucket "${BE_BUCKET}" --key "$(be_key "${key}")" --body "${src}" \
         "${flag}" "${value}" --checksum-sha256 "${sum}" >/dev/null; then
      rc=0
      break
    fi
    if be_precondition "${errf}"; then
      rc=5
      break
    fi
    if grep -qE 'ConditionalRequestConflict|\(409\)' "${errf}" && (( attempt < 3 )); then
      sleep 1
      continue
    fi
    cat "${errf}" >&2
    rc=1
    break
  done
  rm -f "${errf}"
  return "${rc}"
}

be_put_create() {
  be_put_cond "$1" "$2" --if-none-match '*'
}

be_put_cas() {
  if [[ "$3" == "absent" ]]; then
    be_put_cond "$1" "$2" --if-none-match '*'
  else
    be_put_cond "$1" "$2" --if-match "\"$3\""
  fi
}

be_list() {
  local errf out full
  full="$(be_key "$1")"
  errf="$(mktemp)"
  if ! out="$(be_aws "${errf}" list-objects-v2 --bucket "${BE_BUCKET}" --prefix "${full}")"; then
    cat "${errf}" >&2
    rm -f "${errf}"
    return 1
  fi
  rm -f "${errf}"
  [[ -n "${out}" ]] || return 0
  printf '%s' "${out}" | jq -r --arg p "${BE_PREFIX:+${BE_PREFIX}/}" \
    '.Contents[]?.Key | select(startswith($p)) | .[($p | length):]' | LC_ALL=C sort
}

# be_delete_if <key> <token>: deletes only while the object still has the
# ETag <token> (S3 conditional delete, If-Match). 0 deleted, 4 missing,
# 5 changed, 1 error.
be_delete_if() {
  local errf rc
  errf="$(mktemp)"
  if be_aws "${errf}" delete-object --bucket "${BE_BUCKET}" --key "$(be_key "$1")" --if-match "\"$2\"" >/dev/null; then
    rm -f "${errf}"
    return 0
  fi
  if be_precondition "${errf}"; then
    rc=5
  elif be_missing "${errf}"; then
    rc=4
  else
    cat "${errf}" >&2
    rc=1
  fi
  rm -f "${errf}"
  return "${rc}"
}
