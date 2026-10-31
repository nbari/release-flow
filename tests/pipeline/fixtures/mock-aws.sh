#!/usr/bin/env bash
# Mock `aws s3api` over ${MOCK_S3_ROOT}/<bucket>/<key> with S3 conditional
# semantics: If-None-Match: * (create-only), If-Match: <etag> (CAS) and
# If-Match: <etag> on delete-object (conditional delete).
# The ETag is the content sha256. Every call is appended to
# ${MOCK_S3_ROOT}/calls.log. MOCK_AWS_NO_CONDITIONAL=1 simulates a CLI without
# conditional-write support.
set -euo pipefail

root="${MOCK_S3_ROOT:?MOCK_S3_ROOT is required}"
mkdir -p "${root}"
printf 'aws %s\n' "$*" >> "${root}/calls.log"

[[ "${1:-}" == "s3api" ]] || { echo "mock-aws: only s3api is supported" >&2; exit 252; }
op="${2:-}"
shift 2

if [[ "${1:-}" == "help" ]]; then
  if [[ "${op}" == "put-object" && "${MOCK_AWS_NO_CONDITIONAL:-}" != "1" ]]; then
    printf 'PUT-OBJECT()\n  [--if-match <value>]\n  [--if-none-match <value>]\n  [--checksum-sha256 <value>]\n'
  else
    printf '%s\n  [--checksum-sha256 <value>]\n' "${op}"
  fi
  exit 0
fi

bucket="" key="" body="" if_none="" if_match="" checksum="" prefix="" positional=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bucket) bucket="$2"; shift 2 ;;
    --key) key="$2"; shift 2 ;;
    --body) body="$2"; shift 2 ;;
    --if-none-match) if_none="$2"; shift 2 ;;
    --if-match) if_match="$2"; shift 2 ;;
    --checksum-sha256) checksum="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --output|--endpoint-url|--region|--query) shift 2 ;;
    --*) shift 2 ;;
    *) positional="$1"; shift ;;
  esac
done

obj="${root}/${bucket}/${key}"
etag() { sha256sum "$1" | awk '{print $1}'; }
fail() {
  printf '\nAn error occurred (%s) when calling the %s operation: %s\n' "$1" "$2" "$3" >&2
  exit 254
}

case "${op}" in
  head-object)
    [[ -f "${obj}" ]] || fail 404 HeadObject "Not Found"
    printf '{"ETag": "\\"%s\\"", "ContentLength": %s}\n' "$(etag "${obj}")" "$(wc -c < "${obj}" | tr -d ' ')"
    ;;
  get-object)
    [[ -f "${obj}" ]] || fail NoSuchKey GetObject "The specified key does not exist."
    cp "${obj}" "${positional}"
    printf '{"ETag": "\\"%s\\""}\n' "$(etag "${obj}")"
    ;;
  put-object)
    if [[ -n "${checksum}" ]]; then
      actual="$(sha256sum "${body}" | awk '{print $1}' | sed 's/../\\x&/g')"
      # shellcheck disable=SC2059
      actual="$(printf "${actual}" | base64 | tr -d '\n')"
      [[ "${actual}" == "${checksum}" ]] || fail BadDigest PutObject "The SHA256 you specified did not match the calculated checksum."
    fi
    lock="${root}/.lock"
    exec 9> "${lock}"
    flock 9
    if [[ "${if_none}" == "*" && -f "${obj}" ]]; then
      fail PreconditionFailed PutObject "At least one of the pre-conditions you specified did not hold"
    fi
    if [[ -n "${if_match}" ]]; then
      want="${if_match//\"/}"
      if [[ ! -f "${obj}" || "$(etag "${obj}")" != "${want}" ]]; then
        fail PreconditionFailed PutObject "At least one of the pre-conditions you specified did not hold"
      fi
    fi
    mkdir -p "$(dirname "${obj}")"
    cp "${body}" "${obj}.mocktmp"
    mv "${obj}.mocktmp" "${obj}"
    printf '{"ETag": "\\"%s\\""}\n' "$(etag "${obj}")"
    ;;
  list-objects-v2)
    dir="${root}/${bucket}"
    if [[ ! -d "${dir}" ]]; then
      printf '{}\n'
      exit 0
    fi
    (cd "${dir}" && find . -type f | sed 's|^\./||' | sort) \
      | awk -v p="${prefix}" 'substr($0, 1, length(p)) == p' \
      | jq -R -s 'split("\n") | map(select(length > 0)) | if length == 0 then {} else {Contents: map({Key: .})} end'
    ;;
  delete-object)
    exec 9> "${root}/.lock"
    flock 9
    if [[ -n "${if_match}" ]]; then
      [[ -f "${obj}" ]] || fail NoSuchKey DeleteObject "The specified key does not exist."
      if [[ "$(etag "${obj}")" != "${if_match//\"/}" ]]; then
        fail PreconditionFailed DeleteObject "At least one of the pre-conditions you specified did not hold"
      fi
    fi
    rm -f "${obj}"
    printf '{}\n'
    ;;
  *)
    echo "mock-aws: unsupported operation ${op}" >&2
    exit 252
    ;;
esac
