#!/usr/bin/env bash
# Mock cargo for crates.io publisher tests. Every call is appended to
# ${MOCK_CARGO_LOG}. `+<toolchain>` is accepted and ignored.
#   package  writes target/package/<pkg>-<V>.crate with the stub adapter's
#            deterministic bytes ("stub crate <V>"); MOCK_CARGO_FAULT=package-differs
#            writes different bytes. <pkg> is the --package value, else
#            ${MOCK_CARGO_PACKAGE:-stub}; <V> the VERSION file of the current
#            directory.
#   publish  packages, then appends {"name","vers","cksum"} to the sparse index
#            directory ${MOCK_CARGO_INDEX}. MOCK_CARGO_FAULT=publish-fail fails;
#            MOCK_CARGO_FAULT=already-uploaded models a lost earlier upload:
#            the version reaches the index, then publish fails the way
#            crates.io refuses a version uploaded before.
set -euo pipefail

log="${MOCK_CARGO_LOG:?MOCK_CARGO_LOG is required}"
printf 'cargo %s\n' "$*" >> "${log}"

if [[ "${1:-}" == +* ]]; then
  shift
fi

pkg="${MOCK_CARGO_PACKAGE:-stub}"
prev=""
for arg in "$@"; do
  [[ "${prev}" == "--package" || "${prev}" == "-p" ]] && pkg="${arg}"
  prev="${arg}"
done
version="$(head -n 1 VERSION | tr -d '\r\n ')"
crate="target/package/${pkg}-${version}.crate"

do_package() {
  mkdir -p target/package
  if [[ "${MOCK_CARGO_FAULT:-}" == "package-differs" ]]; then
    printf 'stub crate %s rebuilt differently\n' "${version}" > "${crate}"
  else
    printf 'stub crate %s\n' "${version}" > "${crate}"
  fi
}

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

case "${1:-}" in
  package)
    do_package
    ;;
  publish)
    [[ "${MOCK_CARGO_FAULT:-}" != "publish-fail" ]] || { echo "error: failed to publish" >&2; exit 101; }
    do_package
    idx="${MOCK_CARGO_INDEX:?MOCK_CARGO_INDEX is required}/$(index_path "${pkg}")"
    mkdir -p "$(dirname "${idx}")"
    jq -nc --arg n "${pkg}" --arg v "${version}" --arg c "$(sha256sum "${crate}" | awk '{print $1}')" \
      '{name: $n, vers: $v, deps: [], cksum: $c, features: {}, yanked: false}' >> "${idx}"
    if [[ "${MOCK_CARGO_FAULT:-}" == "already-uploaded" ]]; then
      echo "error: failed to publish to registry at https://crates.io" >&2
      echo "" >&2
      echo "Caused by:" >&2
      echo "  the remote server responded with an error (status 400 Bad Request): crate version \`${version}\` is already uploaded" >&2
      exit 101
    fi
    ;;
  *)
    echo "mock-cargo: unsupported command: $*" >&2
    exit 101
    ;;
esac
