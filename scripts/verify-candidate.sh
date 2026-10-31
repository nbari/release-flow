#!/usr/bin/env bash
# Verify candidate artifact inventory and provenance of its declared source commit.
set -euo pipefail

if (( $# != 2 )); then
  echo 'usage: verify-candidate.sh <artifact-directory> <expected-commit-sha>' >&2
  exit 2
fi

readonly directory="$1" expected_commit="$2"
[[ -d "${directory}" ]] || { echo "Missing artifact directory: ${directory}" >&2; exit 1; }
[[ "${expected_commit}" =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid expected commit SHA" >&2; exit 2; }
for file in manifest.json SHA256SUMS; do
  [[ -f "${directory}/${file}" ]] || { echo "Missing ${file}" >&2; exit 1; }
done

commit="$(jq -er '.commit | strings' "${directory}/manifest.json")"
version="$(jq -er '.version | strings' "${directory}/manifest.json")"
archive="$(jq -er '.archive | strings' "${directory}/manifest.json")"
[[ "${commit}" == "${expected_commit}" ]] || { echo "Manifest commit mismatch" >&2; exit 1; }
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid manifest version" >&2; exit 1; }
[[ "${archive}" == "release-flow-${version}-x86_64-unknown-linux-gnu.tar.gz" ]] || {
  echo "Unexpected archive name: ${archive}" >&2
  exit 1
}
[[ -f "${directory}/${archive}" ]] || { echo "Missing archive" >&2; exit 1; }

# Exactly one checksum entry and exactly one release archive: never silently ship extras.
[[ "$(wc -l < "${directory}/SHA256SUMS")" -eq 1 ]] || { echo "Unexpected checksum inventory" >&2; exit 1; }
[[ "$(awk '{print $2}' "${directory}/SHA256SUMS")" == "${archive}" ]] || {
  echo "Checksum does not name the expected archive" >&2
  exit 1
}
file_count="$(find "${directory}" -maxdepth 1 -type f | wc -l)"
[[ "${file_count}" -eq 3 ]] || { echo "Unexpected extra files in artifact" >&2; exit 1; }
(
  cd "${directory}"
  sha256sum --check --strict SHA256SUMS
)
if ! tar -tzf "${directory}/${archive}" | grep -Fx './release-flow' >/dev/null; then
  echo "Archive does not contain the expected executable" >&2
  exit 1
fi
printf 'Validated candidate %s at %s\n' "${version}" "${commit}"
