#!/usr/bin/env bash
# release-flow-adapter: 1
# Project adapter for release-flow itself: the Cargo reference adapter per
# platform, plus the platform-independent artifacts (target "any"): the
# versioned distribution bundle (release-flow-bundle-<V>.tar.gz) and the
# crates.io package (<package>-<V>.crate) that the crates-io publisher must
# reproduce byte for byte.
#
#   targets                     the candidate.yml package matrix
#   inventory <V>               artifacts of the targets in RELEASE_FLOW_TARGETS
#   package <V> <outdir>        RELEASE_FLOW_TARGET selects one leg; unset packages
#                               every target in RELEASE_FLOW_TARGETS
#
# RELEASE_FLOW_TARGETS (space-separated, default: every target) filters the
# inventory and unset-target packaging. RELEASE_FLOW_CARGO_TARGETS overrides
# the platform list ("<rust-target>[:<runner>] ...").
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "${dir}/../.." && pwd)"

subcommand="${1:-}"

RELEASE_FLOW_CARGO_TARGETS="${RELEASE_FLOW_CARGO_TARGETS:-x86_64-unknown-linux-musl:ubuntu-24.04 aarch64-unknown-linux-musl:ubuntu-24.04-arm x86_64-apple-darwin:macos-latest x86_64-pc-windows-msvc:windows-latest}"
export RELEASE_FLOW_CARGO_TARGETS

# all_targets: "target<TAB>runner" rows, platform targets then "any"
all_targets() {
  local spec
  for spec in ${RELEASE_FLOW_CARGO_TARGETS}; do
    if [[ "${spec}" == *:* ]]; then
      printf '%s\t%s\n' "${spec%%:*}" "${spec#*:}"
    else
      printf '%s\tubuntu-24.04\n' "${spec}"
    fi
  done
  printf 'any\tubuntu-24.04\n'
}

# selected <target>: the target is in RELEASE_FLOW_TARGETS (default all)
selected() {
  [[ -z "${RELEASE_FLOW_TARGETS:-}" ]] && return 0
  case " ${RELEASE_FLOW_TARGETS} " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# selected_cargo_targets: RELEASE_FLOW_CARGO_TARGETS restricted to the selection
selected_cargo_targets() {
  local spec out=""
  for spec in ${RELEASE_FLOW_CARGO_TARGETS}; do
    if selected "${spec%%:*}"; then
      out+="${spec} "
    fi
  done
  printf '%s' "${out% }"
}

package_name() {
  cargo metadata --no-deps --format-version 1 | jq -er '.packages[0].name'
}

case "${subcommand}" in
  version|set-version)
    exec "${dir}/cargo.sh" "$@"
    ;;

  verify)
    "${dir}/cargo.sh" verify
    if [[ "${GITHUB_ACTIONS:-}" == true ]] && ! command -v just >/dev/null 2>&1; then
      bash "${root}/tests/pipeline/ci-install-just.sh"
      export PATH="${RUNNER_TEMP}/just-bin:${PATH}"
    fi
    bash "${root}/tests/pipeline/run.sh"
    ;;

  targets)
    all_targets | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {target: .[0], runner: .[1]})'
    ;;

  inventory)
    target_version="${2:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: release-flow.sh inventory <X.Y.Z>" >&2
      exit 2
    fi
    cargo_targets="$(selected_cargo_targets)"
    if [[ -n "${cargo_targets}" ]]; then
      inv="$(RELEASE_FLOW_CARGO_TARGETS="${cargo_targets}" "${dir}/cargo.sh" inventory "${target_version}")"
    else
      inv="$(RELEASE_FLOW_CARGO_TARGETS="none" "${dir}/cargo.sh" inventory "${target_version}" | jq '.artifacts = []')"
    fi
    if selected any; then
      inv="$(printf '%s' "${inv}" | jq --arg b "release-flow-bundle-${target_version}.tar.gz" \
        --arg c "$(package_name)-${target_version}.crate" '.artifacts += [{name: $b, target: "any"}, {name: $c, target: "any"}]')"
    fi
    printf '%s\n' "${inv}"
    ;;

  package)
    target_version="${2:-}"
    outdir="${3:-}"
    if [[ -z "${target_version}" || -z "${outdir}" ]]; then
      echo "Usage: release-flow.sh package <X.Y.Z> <outdir>" >&2
      exit 2
    fi
    leg="${RELEASE_FLOW_TARGET:-}"
    if [[ -n "${leg}" ]] && ! all_targets | cut -f1 | grep -qxF "${leg}"; then
      echo "Unknown target: ${leg}" >&2
      exit 2
    fi
    # Cargo first: it refuses a non-empty output directory.
    cargo_targets="$(selected_cargo_targets)"
    if [[ -n "${cargo_targets}" ]]; then
      RELEASE_FLOW_CARGO_TARGETS="${cargo_targets}" RELEASE_FLOW_TARGET="${leg}" \
        "${dir}/cargo.sh" package "${target_version}" "${outdir}"
    else
      # No platform target selected: validates the version and outdir, builds nothing.
      RELEASE_FLOW_CARGO_TARGETS="none" RELEASE_FLOW_TARGET="any" \
        "${dir}/cargo.sh" package "${target_version}" "${outdir}"
    fi
    if [[ "${leg}" == "any" ]] || [[ -z "${leg}" ]] && selected any; then
      pkg="$(package_name)"
      cargo package --locked --no-verify --quiet >&2
      target_dir="$(cargo metadata --no-deps --format-version 1 | jq -er '.target_directory')"
      cp "${target_dir}/package/${pkg}-${target_version}.crate" "${outdir}/${pkg}-${target_version}.crate"
      bash "${root}/scripts/release-flow-bundle.sh" --version "${target_version}" --out "${outdir}" >/dev/null
    fi
    ;;

  *)
    echo "Unknown subcommand: ${subcommand}" >&2
    exit 2
    ;;
esac
