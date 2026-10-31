#!/usr/bin/env bash
# Release pipeline smoke test: accepts a correct manifest, rejects tampered artifacts.
set -euo pipefail

readonly root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
readonly commit="1111111111111111111111111111111111111111"
readonly version="0.1.0"
readonly archive="release-flow-${version}-x86_64-unknown-linux-gnu.tar.gz"

mkdir -p "${work}/stage"
printf 'demo binary\n' > "${work}/stage/release-flow"
tar -C "${work}/stage" -czf "${work}/${archive}" .
(cd "${work}" && sha256sum "${archive}" > SHA256SUMS)
jq -n --arg version "${version}" --arg commit "${commit}" --arg archive "${archive}" \
  '{version: $version, commit: $commit, archive: $archive}' > "${work}/manifest.json"

bash "${root}/scripts/verify-candidate.sh" "${work}" "${commit}"
if bash "${root}/scripts/verify-candidate.sh" "${work}" "2222222222222222222222222222222222222222" >/dev/null 2>&1; then
  echo 'Expected wrong commit to be rejected' >&2
  exit 1
fi
printf 'tampered\n' >> "${work}/${archive}"
if bash "${root}/scripts/verify-candidate.sh" "${work}" "${commit}" >/dev/null 2>&1; then
  echo 'Expected tampered archive to be rejected' >&2
  exit 1
fi
echo 'Candidate verifier accepted valid input and rejected tampering.'
