#!/usr/bin/env bash
# Project adapter for release-flow itself: the Cargo reference adapter plus the
# versioned distribution bundle (release-flow-bundle-<V>.tar.gz) as an artifact.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${dir}/../.." && pwd)"

subcommand="${1:-}"

case "${subcommand}" in
  version|set-version|verify)
    exec "${dir}/cargo.sh" "$@"
    ;;

  inventory)
    target_version="${2:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: release-flow.sh inventory <X.Y.Z>" >&2
      exit 2
    fi
    "${dir}/cargo.sh" inventory "${target_version}" \
      | jq --arg n "release-flow-bundle-${target_version}.tar.gz" '.artifacts += [{name: $n, target: "any"}]'
    ;;

  package)
    target_version="${2:-}"
    outdir="${3:-}"
    if [[ -z "${target_version}" || -z "${outdir}" ]]; then
      echo "Usage: release-flow.sh package <X.Y.Z> <outdir>" >&2
      exit 2
    fi
    # Cargo first: it refuses a non-empty output directory.
    "${dir}/cargo.sh" package "${target_version}" "${outdir}"
    bash "${root}/scripts/release-flow-bundle.sh" --version "${target_version}" --out "${outdir}" >/dev/null
    ;;

  *)
    echo "Unknown subcommand: ${subcommand}" >&2
    exit 2
    ;;
esac
