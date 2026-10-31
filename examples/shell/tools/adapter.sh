#!/usr/bin/env bash
# release-flow-adapter: 1
# Run from the consumer root. Requires Bash, jq, GNU tar and gzip only.
set -euo pipefail
command="${1:-}"
version="${2:-}"
valid_version() { [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; }
case "${command}" in
  version) cat VERSION ;;
  set-version)
    valid_version "${version}" || exit 2
    printf '%s\n' "${version}" > VERSION
    echo VERSION
    ;;
  verify)
    bash -n tools/adapter.sh
    sh -n app/hello.sh
    test "$(sh app/hello.sh)" = 'Hello from a language-neutral release'
    ;;
  targets) printf '[{"target":"any","runner":"ubuntu-24.04"}]\n' ;;
  inventory)
    valid_version "${version}" || exit 2
    jq -n --arg name "hello-${version}.tar.gz" \
      '{artifacts:[{name:$name,target:"any"}],build_info:{tools:{shell:"POSIX"}}}'
    ;;
  package)
    valid_version "${version}" || exit 2
    [[ "$(cat VERSION)" == "${version}" ]] || { echo 'Version mismatch' >&2; exit 1; }
    out="${3:?Usage: adapter package X.Y.Z OUTDIR}"
    [[ "${SOURCE_DATE_EPOCH:-}" =~ ^[0-9]+$ ]] || { echo 'SOURCE_DATE_EPOCH must be numeric' >&2; exit 1; }
    [[ ! -e "${out}" || ( -d "${out}" && -z "$(ls -A "${out}")" ) ]] || { echo 'Output directory must be empty' >&2; exit 1; }
    mkdir -p "${out}"
    tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
      --mode='u+rwX,go+rX,go-w' -cf - VERSION app | gzip -n > "${out}/hello-${version}.tar.gz"
    ;;
  *) echo 'Expected version, set-version, verify, targets, inventory or package' >&2; exit 2 ;;
esac
