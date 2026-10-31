#!/usr/bin/env bash
# Install a pinned, checksum-verified `just` for CI (no third-party actions).
# No-op when a just >= 1.27.0 is already on PATH. The install directory is
# appended to $GITHUB_PATH (when set) so later workflow steps can use it.
set -euo pipefail

JUST_VERSION="1.58.0"
JUST_TARGET="x86_64-unknown-linux-musl"
# From https://github.com/casey/just/releases/download/1.58.0/SHA256SUMS
JUST_SHA256="4a5cc2f53e6f0f8c59092a6cc38291eb729d46a7dd95d3ae582008881b84931d"

just_ok() {
  local v major minor
  command -v just >/dev/null 2>&1 || return 1
  v="$(just --version 2>/dev/null | awk '{print $2}')"
  IFS='.' read -r major minor _ <<< "${v}"
  [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ ]] || return 1
  (( major > 1 || (major == 1 && minor >= 27) ))
}

if just_ok; then
  echo "Using existing $(just --version) at $(command -v just)" >&2
  exit 0
fi

if [[ "$(uname -s)" != "Linux" || "$(uname -m)" != "x86_64" ]]; then
  echo "ci-install-just.sh only supports Linux x86_64; install just >= 1.27.0 manually" >&2
  exit 1
fi

install_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/just-bin"
archive_name="just-${JUST_VERSION}-${JUST_TARGET}.tar.gz"
url="https://github.com/casey/just/releases/download/${JUST_VERSION}/${archive_name}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "${work}/${archive_name}" "${url}"
actual="$(sha256sum "${work}/${archive_name}" | awk '{print $1}')"
if [[ "${actual}" != "${JUST_SHA256}" ]]; then
  echo "Checksum mismatch for ${archive_name}: expected ${JUST_SHA256}, got ${actual}" >&2
  exit 1
fi

mkdir -p "${install_dir}"
tar -xzf "${work}/${archive_name}" -C "${install_dir}" just
chmod 0755 "${install_dir}/just"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${install_dir}" >> "${GITHUB_PATH}"
fi
PATH="${install_dir}:${PATH}"
export PATH

echo "Installed $("${install_dir}/just" --version) to ${install_dir}" >&2
