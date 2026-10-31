#!/usr/bin/env bash
# Stub project adapter for testing release-flow orchestration without language toolchains.
set -euo pipefail

subcommand="${1:-}"
shift || true

fault="${STUB_FAULT:-none}"

case "${subcommand}" in
  version)
    if [[ ! -f VERSION ]]; then
      echo "Missing VERSION file" >&2
      exit 1
    fi
    head -n 1 VERSION | tr -d '\r\n '
    printf '\n'
    ;;

  set-version)
    target_version="${1:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: adapter set-version <version>" >&2
      exit 2
    fi
    if [[ ! "${target_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid version: ${target_version}" >&2
      exit 2
    fi

    case "${fault}" in
      set-version-fail)
        echo "Simulated adapter set-version failure" >&2
        exit 1
        ;;
      noop)
        echo "VERSION"
        ;;
      undeclared)
        printf '%s\n' "${target_version}" > VERSION
        printf 'stray content\n' > EXTRA
        echo "VERSION"
        ;;
      sigterm)
        if [[ "${STUB_ALLOW_GROUP_KILL:-}" != "1" ]]; then
          echo "sigterm fault refused without STUB_ALLOW_GROUP_KILL=1" >&2
          exit 2
        fi
        kill -TERM 0
        exit 1
        ;;
      sigkill)
        if [[ "${STUB_ALLOW_GROUP_KILL:-}" != "1" ]]; then
          echo "sigkill fault refused without STUB_ALLOW_GROUP_KILL=1" >&2
          exit 2
        fi
        kill -KILL 0
        exit 1
        ;;
      *)
        printf '%s\n' "${target_version}" > VERSION
        echo "VERSION"
        ;;
    esac
    ;;

  verify)
    exit 0
    ;;

  inventory)
    target_version="${1:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: adapter inventory <version>" >&2
      exit 2
    fi
    cat <<EOF
{
  "artifacts": [
    {
      "name": "stub-${target_version}-any.txt",
      "target": "any"
    }
  ],
  "build_info": {
    "stub": "1"
  }
}
EOF
    ;;

  package)
    target_version="${1:-}"
    outdir="${2:-}"
    if [[ -z "${target_version}" || -z "${outdir}" ]]; then
      echo "Usage: adapter package <version> <outdir>" >&2
      exit 2
    fi
    if [[ -z "${SOURCE_DATE_EPOCH:-}" || ! "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]]; then
      echo "SOURCE_DATE_EPOCH is required and must be numeric" >&2
      exit 1
    fi

    current_version="$(head -n 1 VERSION | tr -d '\r\n ')"
    if [[ "${current_version}" != "${target_version}" ]]; then
      echo "Version mismatch: package version ${target_version} != current version ${current_version}" >&2
      exit 1
    fi

    if [[ -d "${outdir}" ]]; then
      if [[ -n "$(ls -A "${outdir}")" ]]; then
        echo "Refusing to package into non-empty directory: ${outdir}" >&2
        exit 1
      fi
    else
      mkdir -p "${outdir}"
    fi

    case "${fault}" in
      package-missing)
        # Writes nothing
        ;;
      package-extra)
        printf 'stub %s\n' "${target_version}" > "${outdir}/stub-${target_version}-any.txt"
        printf 'extra stray artifact\n' > "${outdir}/stray.bin"
        ;;
      *)
        printf 'stub %s\n' "${target_version}" > "${outdir}/stub-${target_version}-any.txt"
        ;;
    esac
    ;;

  *)
    echo "Unknown subcommand: ${subcommand}" >&2
    exit 2
    ;;
esac
