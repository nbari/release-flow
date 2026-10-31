#!/usr/bin/env bash
# Stub project adapter for testing release-flow orchestration without language toolchains.
#
#   STUB_FAULT       fault injection (see below)
#   STUB_TARGETS     space-separated build targets: enables `targets` and one
#                    stub-<V>-<target>.txt artifact per target
#   STUB_ARTIFACTS   "full" adds publishable artifacts: an OCI image layout
#                    (stub-<V>-oci.tar), a crate (stub-<V>.crate), docs
#                    (stub-<V>-docs.tar.gz) and a Helm chart (stub-chart-<V>.tgz)
#   STUB_LOG         every subcommand is appended to this file
#   RELEASE_FLOW_TARGET  package only the inventory entries of this target
set -euo pipefail

subcommand="${1:-}"
shift || true

fault="${STUB_FAULT:-none}"

if [[ -n "${STUB_LOG:-}" ]]; then
  printf '%s\n' "${subcommand}" >> "${STUB_LOG}"
fi

# inventory_rows <version>: "name<TAB>target" per artifact.
inventory_rows() {
  local v="$1" t
  if [[ -n "${STUB_TARGETS:-}" ]]; then
    for t in ${STUB_TARGETS}; do
      printf 'stub-%s-%s.txt\t%s\n' "${v}" "${t}" "${t}"
    done
    return 0
  fi
  printf 'stub-%s-any.txt\tany\n' "${v}"
  if [[ "${STUB_ARTIFACTS:-}" == "full" ]]; then
    printf 'stub-%s-oci.tar\tany\n' "${v}"
    printf 'stub-%s.crate\tany\n' "${v}"
    printf 'stub-%s-docs.tar.gz\tany\n' "${v}"
    printf 'stub-chart-%s.tgz\tany\n' "${v}"
  fi
}

det_tar() {
  # det_tar <dir> <out> [extra tar args...]: deterministic tar of <dir>'s contents
  local dir="$1" out="$2"
  shift 2
  (cd "${dir}" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort > "${dir}.list")
  tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
    --mode='u+rwX,go+rX,go-w' "$@" -C "${dir}" -cf "${out}" --no-recursion -T "${dir}.list"
  rm -f "${dir}.list"
}

sha_of() {
  sha256sum "$1" | awk '{print $1}'
}

write_artifact() {
  local name="$1" v="$2" outdir="$3" work
  work="$(mktemp -d)"
  case "${name}" in
    *-oci.tar)
      local layout="${work}/layout" cfg man cfg_sha cfg_size man_sha man_size
      mkdir -p "${layout}/blobs/sha256"
      printf '{"architecture":"amd64","os":"linux","config":{"Labels":{"version":"%s"}},"rootfs":{"type":"layers","diff_ids":[]}}' "${v}" > "${work}/config.json"
      cfg_sha="$(sha_of "${work}/config.json")"
      cfg_size="$(wc -c < "${work}/config.json" | tr -d ' ')"
      cp "${work}/config.json" "${layout}/blobs/sha256/${cfg_sha}"
      printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"sha256:%s","size":%s},"layers":[]}' "${cfg_sha}" "${cfg_size}" > "${work}/manifest.json"
      man_sha="$(sha_of "${work}/manifest.json")"
      man_size="$(wc -c < "${work}/manifest.json" | tr -d ' ')"
      cp "${work}/manifest.json" "${layout}/blobs/sha256/${man_sha}"
      printf '{"imageLayoutVersion":"1.0.0"}' > "${layout}/oci-layout"
      printf '{"schemaVersion":2,"manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"sha256:%s","size":%s}]}' "${man_sha}" "${man_size}" > "${layout}/index.json"
      det_tar "${layout}" "${outdir}/${name}"
      ;;
    *.crate)
      printf 'stub crate %s\n' "${v}" > "${outdir}/${name}"
      ;;
    *-docs.tar.gz)
      mkdir -p "${work}/docs/api"
      printf '<h1>stub %s</h1>\n' "${v}" > "${work}/docs/index.html"
      printf '<h1>stub %s api</h1>\n' "${v}" > "${work}/docs/api/index.html"
      if [[ "${fault}" == "docs-evil" ]]; then
        printf 'escape\n' > "${work}/docs/evil"
        det_tar "${work}/docs" "${work}/docs.tar" -P --transform 's,^evil$,../evil,'
      else
        det_tar "${work}/docs" "${work}/docs.tar"
      fi
      gzip -n -c "${work}/docs.tar" > "${outdir}/${name}"
      ;;
    stub-chart-*.tgz)
      mkdir -p "${work}/chart/stub-chart"
      chart_version="${v}"
      # chart-version-mismatch: Chart.yaml claims another version than the release
      [[ "${fault}" != "chart-version-mismatch" ]] || chart_version="9.9.9"
      cat <<EOF > "${work}/chart/stub-chart/Chart.yaml"
apiVersion: v2
name: stub-chart
version: ${chart_version}
appVersion: "${v}"
description: Stub chart for release-flow tests
EOF
      det_tar "${work}/chart" "${work}/chart.tar"
      gzip -n -c "${work}/chart.tar" > "${outdir}/${name}"
      ;;
    *)
      printf 'stub %s\n' "${v}" > "${outdir}/${name}"
      ;;
  esac
  rm -rf "${work}"
}

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

  targets)
    if [[ -z "${STUB_TARGETS:-}" ]]; then
      echo "targets: not supported (STUB_TARGETS unset)" >&2
      exit 2
    fi
    for t in ${STUB_TARGETS}; do
      printf '%s\n' "${t}"
    done | jq -R -s -c 'split("\n") | map(select(length > 0) | {target: ., runner: "ubuntu-24.04"})'
    ;;

  inventory)
    target_version="${1:-}"
    if [[ -z "${target_version}" ]]; then
      echo "Usage: adapter inventory <version>" >&2
      exit 2
    fi
    inventory_rows "${target_version}" \
      | jq -R -s '{artifacts: (split("\n") | map(select(length > 0) | split("\t") | {name: .[0], target: .[1]})), build_info: {stub: "1"}}'
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
    outdir="$(cd "${outdir}" && pwd)"

    case "${fault}" in
      package-missing)
        # Writes nothing
        ;;
      *)
        while IFS=$'\t' read -r name target; do
          [[ -n "${name}" ]] || continue
          if [[ -n "${RELEASE_FLOW_TARGET:-}" && "${RELEASE_FLOW_TARGET}" != "${target}" ]]; then
            continue
          fi
          write_artifact "${name}" "${target_version}" "${outdir}"
        done <<< "$(inventory_rows "${target_version}")"
        if [[ "${fault}" == "package-extra" ]]; then
          printf 'extra stray artifact\n' > "${outdir}/stray.bin"
        fi
        ;;
    esac
    ;;

  *)
    echo "Unknown subcommand: ${subcommand}" >&2
    exit 2
    ;;
esac
