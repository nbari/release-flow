#!/usr/bin/env bash
# Install a pinned, checksum-verified ORAS CLI for the OCI publisher in CI
# (no third-party actions). No-op when oras is already on PATH. The install
# directory is appended to $GITHUB_PATH (when set) for later workflow steps.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

ORAS_VERSION="1.3.6"
# From https://github.com/oras-project/oras/releases/download/v1.3.6/oras_1.3.6_checksums.txt
ORAS_SHA256_LINUX_AMD64="66fb0ad7206f3f6fa77ed5b552049d364ccf4b50b1684554f731f76302b52ca0"
ORAS_SHA256_LINUX_ARM64="b84269e78dfc2d5329a4aab373da3200de95e6c138338cf6c66c10c0a3f248c1"
ORAS_SHA256_DARWIN_AMD64="844e26430aa0afe2c40fdbddafc3b39ef968a6d41955b7380684bd02907fa397"
ORAS_SHA256_DARWIN_ARM64="e2b25a53234e2471c5fc81936f957fa612065ab559c21834c02d8bfbc2f62b30"

if command -v oras >/dev/null 2>&1; then
  echo "Using existing $(oras version 2>/dev/null | head -n 1) at $(command -v oras)" >&2
  exit 0
fi

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64) platform="linux_amd64"; want="${ORAS_SHA256_LINUX_AMD64}" ;;
  Linux/aarch64|Linux/arm64) platform="linux_arm64"; want="${ORAS_SHA256_LINUX_ARM64}" ;;
  Darwin/x86_64) platform="darwin_amd64"; want="${ORAS_SHA256_DARWIN_AMD64}" ;;
  Darwin/arm64) platform="darwin_arm64"; want="${ORAS_SHA256_DARWIN_ARM64}" ;;
  *)
    echo "ci-install-oras.sh: unsupported platform $(uname -s)/$(uname -m); install oras ${ORAS_VERSION} manually" >&2
    exit 1
    ;;
esac

install_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/oras-bin"
archive="oras_${ORAS_VERSION}_${platform}.tar.gz"
url="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${archive}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

curl --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "${work}/${archive}" "${url}"
if command -v sha256sum >/dev/null 2>&1; then
  actual="$(sha256sum "${work}/${archive}" | awk '{print $1}')"
else
  actual="$(shasum -a 256 "${work}/${archive}" | awk '{print $1}')"
fi
if [[ "${actual}" != "${want}" ]]; then
  echo "Checksum mismatch for ${archive}: expected ${want}, got ${actual}" >&2
  exit 1
fi

mkdir -p "${install_dir}"
tar -xzf "${work}/${archive}" -C "${install_dir}" oras
chmod 0755 "${install_dir}/oras"

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${install_dir}" >> "${GITHUB_PATH}"
fi
echo "Installed oras ${ORAS_VERSION} to ${install_dir}" >&2
