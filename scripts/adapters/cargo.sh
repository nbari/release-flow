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
    local bin
    bin="$(printf '%s' "${meta}" | jq -er --arg p "${pkg}" '.packages[] | select(.name == $p) | .targets[] | select(.kind[] == "bin") | .name' | head -n 1)"
    if [[ -z "${bin}" ]]; then
      echo "No binary target found for package ${pkg}" >&2
      exit 1
    fi
    printf '%s' "${bin}"
  fi
}

resolve_target() {
  if [[ -n "${RELEASE_FLOW_CARGO_TARGET:-}" ]]; then
    printf '%s' "${RELEASE_FLOW_CARGO_TARGET}"
  else
    rustc -vV | grep '^host:' | awk '{print $2}'
  fi
}

case "${subcommand}" in
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
    rel_manifest="$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1]))' "${manifest_path}")"

    # Check for workspace inheritance
    if grep -Eq '^[[:space:]]*version[[:space:]]*=[[:space:]]*\{[[:space:]]*workspace[[:space:]]*=[[:space:]]*true' "${rel_manifest}" || \
       grep -Eq '^[[:space:]]*version\.workspace[[:space:]]*=[[:space:]]*true' "${rel_manifest}"; then
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
    target="$(resolve_target)"
    rustc_ver="$(rustc --version 2>/dev/null || echo "unknown")"
    cargo_ver="$(cargo --version 2>/dev/null || echo "unknown")"
    lock_hash=""
    if [[ -f "Cargo.lock" ]]; then
      lock_hash="$(sha256sum Cargo.lock | awk '{print $1}')"
    fi

    cat <<EOF
{
  "artifacts": [
    {
      "name": "${pkg}-${target_version}-${target}.tar.gz",
      "target": "${target}"
    }
  ],
  "build_info": {
    "tools": {
      "rustc": "${rustc_ver}",
      "cargo": "${cargo_ver}",
      "cargo_lock_sha256": "${lock_hash}"
    }
  }
}
EOF
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
    target="$(resolve_target)"
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

    if [[ -n "${RELEASE_FLOW_CARGO_TARGET:-}" ]]; then
      cargo build --release --locked --target "${RELEASE_FLOW_CARGO_TARGET}"
      bin_path="target/${RELEASE_FLOW_CARGO_TARGET}/release/${bin_name}"
    else
      cargo build --release --locked
      bin_path="target/release/${bin_name}"
    fi

    stage_dir="$(mktemp -d)"
    trap 'rm -rf "${stage_dir}"' EXIT

    cp "${bin_path}" "${stage_dir}/"
    for doc in LICENSE LICENSE-* COPYING COPYING-* README.md; do
      if [[ -f "${doc}" ]]; then
        cp "${doc}" "${stage_dir}/"
      fi
    done

    archive_name="${pkg}-${target_version}-${target}.tar.gz"
    tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
      --mode='u+rwX,go+rX,go-w' -C "${stage_dir}" -cf - . | gzip -n > "${outdir}/${archive_name}"

    rm -rf "${stage_dir}"
    trap - EXIT
    ;;

  *)
    echo "Unknown subcommand: ${subcommand}" >&2
    exit 2
    ;;
esac
