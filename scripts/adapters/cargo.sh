#!/usr/bin/env bash
# Cargo project adapter for release-flow.
set -euo pipefail

subcommand="${1:-}"
shift || true

resolve_package() {
  local meta
  meta="$(cargo metadata --no-deps --format-version 1)"
  if [[ -n "${RELEASE_FLOW_CARGO_PACKAGE:-}" ]]; then
    printf '%s' "${RELEASE_FLOW_CARGO_PACKAGE}"
  else
    local count
    count="$(printf '%s' "${meta}" | jq '.packages | length')"
    if [[ "${count}" -ne 1 ]]; then
      echo "Ambiguous Cargo workspace: set RELEASE_FLOW_CARGO_PACKAGE" >&2
      exit 1
    fi
    printf '%s' "${meta}" | jq -er '.packages[0].name'
  fi
}

resolve_bin() {
  local pkg="$1" meta
  meta="$(cargo metadata --no-deps --format-version 1)"
  if [[ -n "${RELEASE_FLOW_CARGO_BIN:-}" ]]; then
    printf '%s' "${RELEASE_FLOW_CARGO_BIN}"
  else
    local bins bin_count
    bins="$(printf '%s' "${meta}" | jq -er --arg p "${pkg}" '[.packages[] | select(.name == $p) | .targets[] | select(.kind[] == "bin") | .name]')"
    bin_count="$(printf '%s' "${bins}" | jq 'length')"
    if [[ "${bin_count}" -eq 0 ]]; then
      echo "No binary target found for package ${pkg}" >&2
      exit 1
    elif [[ "${bin_count}" -gt 1 ]]; then
      echo "Ambiguous binary targets for package ${pkg}: specify RELEASE_FLOW_CARGO_BIN" >&2
      exit 1
    fi
    printf '%s' "${bins}" | jq -er '.[0]'
  fi
}

resolve_target() {
  if [[ -n "${RELEASE_FLOW_CARGO_TARGET:-}" ]]; then
    printf '%s' "${RELEASE_FLOW_CARGO_TARGET}"
  else
    rustc -vV | grep '^host:' | awk '{print $2}'
  fi
}

# RELEASE_FLOW_CARGO_TARGETS: space-separated "<rust-target>[:<runner>]" list
# (runner defaults to ubuntu-24.04). Unset: a single target, the host (or
# RELEASE_FLOW_CARGO_TARGET).
configured_targets() {
  local spec
  for spec in ${RELEASE_FLOW_CARGO_TARGETS:-}; do
    if [[ "${spec}" == *:* ]]; then
      printf '%s\t%s\n' "${spec%%:*}" "${spec#*:}"
    else
      printf '%s\tubuntu-24.04\n' "${spec}"
    fi
  done
}

build_targets() {
  if [[ -n "${RELEASE_FLOW_CARGO_TARGETS:-}" ]]; then
    configured_targets | cut -f1
  else
    resolve_target
    printf '\n'
  fi
}

case "${subcommand}" in
  targets)
    if [[ -z "${RELEASE_FLOW_CARGO_TARGETS:-}" ]]; then
      echo "targets: set RELEASE_FLOW_CARGO_TARGETS (\"<rust-target>[:<runner>] ...\") for a multi-platform matrix" >&2
      exit 2
    fi
    configured_targets | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t") | {target: .[0], runner: .[1]})'
    ;;

  version)
    pkg="$(resolve_package)"
    cargo metadata --no-deps --format-version 1 | jq -er --arg p "${pkg}" '.packages[] | select(.name == $p) | .version'
    ;;

  set-version)
    target_version="${1:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: cargo.sh set-version <X.Y.Z>" >&2
      exit 2
    fi
    if [[ ! "${target_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "Invalid SemVer version: ${target_version}" >&2
      exit 2
    fi

    pkg="$(resolve_package)"
    manifest_path="$(cargo metadata --no-deps --format-version 1 | jq -er --arg p "${pkg}" '.packages[] | select(.name == $p) | .manifest_path')"
    rel_manifest="${manifest_path#"$PWD"/}"

    # Check for workspace inheritance in [package] section only
    is_workspace_inherited="$(awk '
      BEGIN { in_pkg = 0; inherited = 0 }
      /^\[package\]/ { in_pkg = 1; next }
      /^\[/ { in_pkg = 0; next }
      in_pkg && /^[[:space:]]*version(\.workspace|[[:space:]]*=[[:space:]]*\{[[:space:]]*workspace)[[:space:]]*=[[:space:]]*true/ {
        inherited = 1;
      }
      END { print inherited }
    ' "${rel_manifest}")"
    if [[ "${is_workspace_inherited}" -eq 1 ]]; then
      echo "Workspace-inherited versioning not directly supported for single-package edit" >&2
      exit 1
    fi
    awk -v ver="${target_version}" '
      BEGIN { in_pkg = 0; replaced = 0 }
      /^\[package\]/ { in_pkg = 1; print; next }
      /^\[/ { in_pkg = 0; print; next }
      in_pkg && !replaced && /^[[:space:]]*version[[:space:]]*=[[:space:]]*"[^"]+"/ {
        sub(/"[^"]+"/, "\"" ver "\"");
        replaced = 1;
        print;
        next
      }
      { print }
      END {
        if (!replaced) {
          exit 1;
        }
      }
    ' "${rel_manifest}" > "${rel_manifest}.tmp"
    mv "${rel_manifest}.tmp" "${rel_manifest}"

    # Lockfile update with lock-drift guard
    lockfile="Cargo.lock"
    if [[ -f "${lockfile}" ]]; then
      cp "${lockfile}" "${lockfile}.orig"
      cargo update --workspace --quiet
      diff_lines="$(diff -u "${lockfile}.orig" "${lockfile}" | grep '^[+-]version = ' || true)"
      add_count="$(printf '%s\n' "${diff_lines}" | grep -c '^+' || true)"
      del_count="$(printf '%s\n' "${diff_lines}" | grep -c '^-' || true)"
      # Must be exactly 1 addition and 1 deletion of version
      if [[ "${add_count}" -ne 1 || "${del_count}" -ne 1 ]]; then
        cp "${lockfile}.orig" "${lockfile}"
        rm -f "${lockfile}.orig"
        echo "Lockfile drift detected during version update" >&2
        exit 1
      fi
      rm -f "${lockfile}.orig"
      printf '%s\n%s\n' "${rel_manifest}" "${lockfile}"
    else
      printf '%s\n' "${rel_manifest}"
    fi
    ;;

  verify)
    cargo fmt --all -- --check
    cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
    cargo test --locked --workspace --all-features
    ;;

  inventory)
    target_version="${1:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: cargo.sh inventory <X.Y.Z>" >&2
      exit 2
    fi
    pkg="$(resolve_package)"
    rustc_ver="$(rustc --version 2>/dev/null || echo "unknown")"
    cargo_ver="$(cargo --version 2>/dev/null || echo "unknown")"
    lock_hash=""
    if [[ -f "Cargo.lock" ]]; then
      lock_hash="$(sha256sum Cargo.lock | awk '{print $1}')"
    fi

    build_targets | jq -R -s --arg pkg "${pkg}" --arg v "${target_version}" \
      --arg rustc "${rustc_ver}" --arg cargo "${cargo_ver}" --arg lock "${lock_hash}" '
      {artifacts: (split("\n") | map(select(length > 0) | {name: ($pkg + "-" + $v + "-" + . + ".tar.gz"), target: .})),
       build_info: {tools: {rustc: $rustc, cargo: $cargo, cargo_lock_sha256: $lock}}}'
    ;;

  package)
    target_version="${1:-}"
    outdir="${2:-}"
    if [[ -z "${target_version}" || -z "${outdir}" ]]; then
      echo "Usage: cargo.sh package <X.Y.Z> <outdir>" >&2
      exit 2
    fi
    if [[ -z "${SOURCE_DATE_EPOCH:-}" || ! "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]]; then
      echo "SOURCE_DATE_EPOCH is required and must be numeric" >&2
      exit 1
    fi

    pkg="$(resolve_package)"
    bin_name="$(resolve_bin "${pkg}")"
    curr_ver="$(cargo metadata --no-deps --format-version 1 | jq -er --arg p "${pkg}" '.packages[] | select(.name == $p) | .version')"
    if [[ "${curr_ver}" != "${target_version}" ]]; then
      echo "Version mismatch: package version ${target_version} != Cargo manifest version ${curr_ver}" >&2
      exit 1
    fi

    if [[ -d "${outdir}" ]]; then
      if [[ -n "$(ls -A "${outdir}")" ]]; then
        echo "Output directory ${outdir} is not empty" >&2
        exit 1
      fi
    else
      mkdir -p "${outdir}"
    fi

    # GNU tar is required for --sort/--owner/--mode (gtar on macOS).
    if tar --version 2>/dev/null | grep -q 'GNU tar'; then
      gnu_tar=tar
    elif command -v gtar >/dev/null 2>&1; then
      gnu_tar=gtar
    else
      echo "GNU tar is required for deterministic archives (install gtar)" >&2
      exit 1
    fi

    target_dir="$(cargo metadata --no-deps --format-version 1 | jq -er '.target_directory')"
    target_dir_rel="${target_dir#"$PWD"/}"
    explicit_target=false
    if [[ -n "${RELEASE_FLOW_CARGO_TARGETS:-}" || -n "${RELEASE_FLOW_CARGO_TARGET:-}" ]]; then
      explicit_target=true
    fi
    host="$(rustc -vV | awk '/^host:/ {print $2}')"

    stage_dir=""
    trap '[[ -z "${stage_dir}" ]] || rm -rf "${stage_dir}"' EXIT
    while IFS= read -r target; do
      [[ -n "${target}" ]] || continue
      # RELEASE_FLOW_TARGET (one candidate.yml matrix leg) selects one target.
      if [[ -n "${RELEASE_FLOW_TARGET:-}" && "${RELEASE_FLOW_TARGET}" != "${target}" ]]; then
        continue
      fi
      bin_file="${bin_name}"
      case "${target}" in
        *-windows-*) bin_file="${bin_name}.exe" ;;
      esac
      if [[ "${explicit_target}" == "true" ]]; then
        if [[ "${target}" != "${host}" ]] && command -v rustup >/dev/null 2>&1; then
          rustup target add "${target}" >&2
        fi
        cargo build --release --locked --package "${pkg}" --bin "${bin_name}" --target "${target}"
        bin_path="${target_dir_rel}/${target}/release/${bin_file}"
      else
        cargo build --release --locked --package "${pkg}" --bin "${bin_name}"
        bin_path="${target_dir_rel}/release/${bin_file}"
      fi

      stage_dir="$(mktemp -d)"
      cp "${bin_path}" "${stage_dir}/"
      for doc in LICENSE LICENSE-* COPYING COPYING-* README.md; do
        if [[ -f "${doc}" ]]; then
          cp "${doc}" "${stage_dir}/"
        fi
      done

      archive_name="${pkg}-${target_version}-${target}.tar.gz"
      "${gnu_tar}" --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
        --mode='u+rwX,go+rX,go-w' -C "${stage_dir}" -cf - . | gzip -n > "${outdir}/${archive_name}"
      rm -rf "${stage_dir}"
      stage_dir=""
    done <<< "$(build_targets)"
    ;;

  *)
    echo "Unknown subcommand: ${subcommand}" >&2
    exit 2
    ;;
esac
