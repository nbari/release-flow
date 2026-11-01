#!/usr/bin/env bash
# release-flow-adapter: 1
# Application packaging policy. Generic Cargo implementation is bundle-managed.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
cargo_adapter="$root/scripts/adapters/cargo.sh"
export RELEASE_FLOW_CARGO_PACKAGE=release-flow
export RELEASE_FLOW_CARGO_BIN=release-flow
export RELEASE_FLOW_CARGO_TARGETS="x86_64-unknown-linux-musl:ubuntu-24.04 aarch64-unknown-linux-musl:ubuntu-24.04-arm x86_64-unknown-linux-gnu:ubuntu-24.04 aarch64-unknown-linux-gnu:ubuntu-24.04-arm x86_64-apple-darwin:macos-15-intel aarch64-apple-darwin:macos-15 x86_64-pc-windows-msvc:windows-2025 aarch64-pc-windows-msvc:windows-11-arm"
command="${1:-}"
shift || true
case "$command" in
  version|set-version) exec bash "$cargo_adapter" "$command" "$@" ;;
  verify)
    bash "$cargo_adapter" verify
    python3 tests/release_contract.py
    ;;
  targets)
    bash "$cargo_adapter" targets | jq '. + [{target:"any",runner:"ubuntu-24.04"}]'
    ;;
  inventory)
    [[ $# == 1 ]] || { echo 'Usage: adapter.sh inventory X.Y.Z' >&2; exit 2; }
    bash "$cargo_adapter" inventory "$1" | jq --arg name "release-flow-$1.crate" \
      '.artifacts += [{name:$name,target:"any"}]'
    ;;
  package)
    [[ $# == 2 ]] || { echo 'Usage: adapter.sh package X.Y.Z OUTDIR' >&2; exit 2; }
    version="$1"
    out="$2"
    selected="${RELEASE_FLOW_TARGET:-}"
    [[ -n "$selected" ]] || { echo 'Set RELEASE_FLOW_TARGET to one declared target; packaging uses native runners' >&2; exit 2; }
    bash "$0" targets | jq -e --arg t "$selected" 'any(.[]; .target==$t)' >/dev/null || { echo "Unknown package target: $selected" >&2; exit 2; }
    [[ -n "${SOURCE_DATE_EPOCH:-}" && "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || { echo 'Numeric SOURCE_DATE_EPOCH is required' >&2; exit 2; }
    [[ "$(bash "$cargo_adapter" version)" == "$version" ]] || { echo 'Package version differs from Cargo.toml' >&2; exit 1; }
    [[ ! -e "$out" || ( -d "$out" && -z "$(ls -A "$out")" ) ]] || { echo 'Package output must be an empty directory' >&2; exit 1; }
    mkdir -p "$out"
    if [[ "$selected" == any ]]; then
      cargo package --locked --no-verify --package release-flow >&2
      target_dir="$(cargo metadata --locked --no-deps --format-version 1 | jq -er .target_directory)"
      cp "$target_dir/package/release-flow-$version.crate" "$out/"
      exit 0
    fi
    case "$(uname -s)" in
      Darwin)
        if ! command -v gtar >/dev/null 2>&1; then
          [[ "${GITHUB_ACTIONS:-}" == true ]] || { echo 'Install GNU tar (brew install gnu-tar)' >&2; exit 1; }
          brew install gnu-tar >&2
        fi
        ;;
      MINGW*|MSYS*) export PATH="/usr/bin:$PATH" ;;
    esac
    case "$selected" in
      x86_64-unknown-linux-musl)
        export CC_x86_64_unknown_linux_musl=musl-gcc
        export CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc
        ;;
      aarch64-unknown-linux-musl)
        export CC_aarch64_unknown_linux_musl=musl-gcc
        export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER=musl-gcc
        ;;
    esac
    if [[ "$selected" == *linux* && "${GITHUB_ACTIONS:-}" == true ]] && ! command -v rpm2archive >/dev/null 2>&1; then
      sudo apt-get update -y >&2
      sudo apt-get install -y rpm rpm2cpio >&2
    fi
    if [[ "$selected" == *linux* ]]; then
      rpm --version >&2
      command -v rpm2archive >&2
    fi
    bash "$cargo_adapter" package "$version" "$out"
    bash "$root/tools/adapter.sh" inventory "$version" | python3 tools/verify-packages.py "$selected" "$version" "$out"
    ;;
  *) echo 'Expected version, set-version, verify, targets, inventory or package' >&2; exit 2 ;;
esac
