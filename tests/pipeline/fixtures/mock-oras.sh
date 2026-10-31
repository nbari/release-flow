#!/usr/bin/env bash
# Mock ORAS CLI over ${MOCK_REGISTRY}:
#   <repo, chars outside [A-Za-z0-9._-] replaced by _>/manifests/<sha256:hex>
#   <repo...>/tags/<tag>   (holds the digest)
#   calls.log              every invocation
# Supports `cp --from-oci-layout <dir>@<digest> <repo>@<digest>`,
# `manifest fetch --descriptor <repo>@<digest>|<repo>:<tag>` and
# `tag <repo>@<digest> <tag>...`.
# Faults: MOCK_ORAS_FAULT=cp-fail|tag-fail. MOCK_ORAS_HOLD=<tag> touches
# held-<tag> and waits (up to 30 s) for release-<tag> before writing that tag.
set -euo pipefail

reg="${MOCK_REGISTRY:?MOCK_REGISTRY is required}"
mkdir -p "${reg}"
printf 'oras %s\n' "$*" >> "${reg}/calls.log"

die() {
  echo "Error: $1" >&2
  exit 1
}

repo_dir() {
  printf '%s/%s' "${reg}" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g')"
}

# split_ref <ref>: sets REF_REPO and REF_DIGEST or REF_TAG
split_ref() {
  REF_REPO="" REF_DIGEST="" REF_TAG=""
  case "$1" in
    *@sha256:*) REF_REPO="${1%@*}"; REF_DIGEST="${1#*@}" ;;
    *:*) REF_REPO="${1%:*}"; REF_TAG="${1##*:}" ;;
    *) die "invalid reference: $1" ;;
  esac
}

case "${1:-}" in
  cp)
    shift
    layout_ref="" dest=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --from-oci-layout) shift ;;
        -*) shift ;;
        *) if [[ -z "${layout_ref}" ]]; then layout_ref="$1"; else dest="$1"; fi; shift ;;
      esac
    done
    [[ "${MOCK_ORAS_FAULT:-}" != "cp-fail" ]] || die "failed to copy: injected registry failure"
    layout="${layout_ref%@*}"
    digest="${layout_ref#*@}"
    [[ -f "${layout}/index.json" && -f "${layout}/oci-layout" ]] || die "${layout} is not an OCI layout"
    blob="${layout}/blobs/sha256/${digest#sha256:}"
    [[ -f "${blob}" ]] || die "${digest}: not found in layout"
    [[ "sha256:$(sha256sum "${blob}" | awk '{print $1}')" == "${digest}" ]] || die "layout blob digest mismatch"
    split_ref "${dest}"
    [[ "${REF_DIGEST}" == "${digest}" ]] || die "destination digest differs from source"
    d="$(repo_dir "${REF_REPO}")"
    mkdir -p "${d}/manifests" "${d}/tags"
    cp "${blob}" "${d}/manifests/${digest}"
    echo "Copied [oci-layout] ${layout_ref} => [registry] ${dest}"
    echo "Digest: ${digest}"
    ;;
  manifest)
    [[ "${2:-}" == "fetch" ]] || die "unsupported manifest subcommand"
    shift 2
    ref=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --descriptor) shift ;;
        -*) shift ;;
        *) ref="$1"; shift ;;
      esac
    done
    split_ref "${ref}"
    d="$(repo_dir "${REF_REPO}")"
    if [[ -n "${REF_TAG}" ]]; then
      [[ -f "${d}/tags/${REF_TAG}" ]] || die "${ref}: not found"
      REF_DIGEST="$(cat "${d}/tags/${REF_TAG}")"
    fi
    m="${d}/manifests/${REF_DIGEST}"
    [[ -f "${m}" ]] || die "${ref}: not found"
    printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":%s}\n' \
      "${REF_DIGEST}" "$(wc -c < "${m}" | tr -d ' ')"
    ;;
  tag)
    shift
    src=""
    tags=()
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -*) shift ;;
        *) if [[ -z "${src}" ]]; then src="$1"; else tags+=("$1"); fi; shift ;;
      esac
    done
    [[ "${MOCK_ORAS_FAULT:-}" != "tag-fail" ]] || die "failed to tag: injected registry failure"
    split_ref "${src}"
    d="$(repo_dir "${REF_REPO}")"
    [[ -f "${d}/manifests/${REF_DIGEST}" ]] || die "${src}: not found"
    for t in "${tags[@]}"; do
      if [[ -n "${MOCK_ORAS_HOLD:-}" && "${MOCK_ORAS_HOLD}" == "${t}" ]]; then
        touch "${reg}/held-${t}"
        for _ in $(seq 1 300); do
          [[ -e "${reg}/release-${t}" ]] && break
          sleep 0.1
        done
      fi
      printf '%s\n' "${REF_DIGEST}" > "${d}/tags/${t}.tmp"
      mv "${d}/tags/${t}.tmp" "${d}/tags/${t}"
      echo "Tagged ${t}"
    done
    ;;
  *)
    die "mock-oras: unsupported command: $*"
    ;;
esac
