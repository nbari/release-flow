#!/usr/bin/env bash
# Build the deterministic, versioned release-flow distribution bundle:
#   <out>/release-flow-bundle-<V>.tar.gz
# Sources are the working-tree files of the repository this script lives in.
# Requires GNU tar (--sort=name); Linux/CI only.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: release-flow-bundle.sh --version X.Y.Z --out DIR
EOF
  exit 2
}

# Files installed into the target repository (paths relative to its root).
PAYLOAD=(
  .justfiles/deploy.just
  scripts/release-deploy.sh
  scripts/release-prepare.sh
  scripts/candidate-guard.sh
  scripts/candidate-manifest.sh
  scripts/verify-candidate.sh
  scripts/candidate-targets.sh
  scripts/release-promote.sh
  scripts/release-status.sh
  scripts/release-retry.sh
  scripts/lib/common.sh
  scripts/lib/github.sh
  scripts/lib/schema.sh
  scripts/lib/tag.sh
  scripts/storage/storage.sh
  scripts/storage/ci-credentials.sh
  scripts/storage/backends/fs.sh
  scripts/storage/backends/s3.sh
  scripts/publication/ci-install-oras.sh
  scripts/publication/latest.sh
  scripts/publication/ledger.sh
  scripts/publication/publish.sh
  scripts/publication/resolve.sh
  scripts/publishers/crates-io.sh
  scripts/publishers/docs.sh
  scripts/publishers/github-release.sh
  scripts/publishers/helm.sh
  scripts/publishers/oci.sh
  .github/workflows/candidate.yml
  .github/workflows/release.yml
)
# Files installed only on request (install.sh --with-cargo-adapter).
OPTIONAL=(
  scripts/adapters/cargo.sh
)
# Bundle support files: bundle path <- source path.
SUPPORT_DST=(install.sh docs/ADOPTION.md docs/release-flow.example.json docs/RULESETS.md
  docs/rulesets/candidates.json docs/rulesets/develop-integrity.json docs/rulesets/develop-review.json
  docs/rulesets/main-integrity.json docs/rulesets/main-promotion.json docs/rulesets/release-tags-create.json
  docs/rulesets/release-tags-immutable.json)
SUPPORT_SRC=(scripts/release-flow-install.sh docs/ADOPTION.md docs/release-flow.example.json docs/RULESETS.md
  docs/rulesets/candidates.json docs/rulesets/develop-integrity.json docs/rulesets/develop-review.json
  docs/rulesets/main-integrity.json docs/rulesets/main-promotion.json docs/rulesets/release-tags-create.json
  docs/rulesets/release-tags-immutable.json)

version=""
out_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || usage
      version="$2"
      shift 2
      ;;
    --out)
      [[ $# -ge 2 ]] || usage
      out_dir="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done
[[ -n "${version}" && -n "${out_dir}" ]] || usage
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid bundle version: ${version} (expected X.Y.Z)" >&2
  exit 2
fi

for tool in git jq tar gzip sha256sum; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "Missing required tool: ${tool}" >&2; exit 1; }
done

src_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

all_sources=("${PAYLOAD[@]}" "${OPTIONAL[@]}" "${SUPPORT_SRC[@]}")
for f in "${all_sources[@]}"; do
  if [[ ! -f "${src_root}/${f}" ]]; then
    echo "Bundle source file missing: ${src_root}/${f}" >&2
    exit 1
  fi
done

source_commit="$(git -C "${src_root}" rev-parse --verify HEAD)"
if [[ -z "$(git -C "${src_root}" status --porcelain --untracked-files=all -- "${all_sources[@]}")" ]]; then
  source_tree_clean=true
else
  source_tree_clean=false
  echo "Warning: bundled source files differ from HEAD ${source_commit:0:12}; source_tree_clean=false" >&2
fi

epoch="${SOURCE_DATE_EPOCH:-$(git -C "${src_root}" log -1 --format=%ct)}"
if [[ ! "${epoch}" =~ ^[0-9]+$ ]]; then
  echo "SOURCE_DATE_EPOCH must be numeric" >&2
  exit 1
fi

mkdir -p "${out_dir}"
out_dir="$(cd "${out_dir}" && pwd)"
bundle_name="release-flow-bundle-${version}"
archive="${out_dir}/${bundle_name}.tar.gz"
if [[ -e "${archive}" ]]; then
  echo "Bundle archive already exists: ${archive}" >&2
  exit 1
fi

stage="$(mktemp -d)"
tmp_archive=""
trap 'rm -rf "${stage}"; [[ -z "${tmp_archive}" ]] || rm -f "${tmp_archive}"' EXIT
bundle_dir="${stage}/${bundle_name}"

file_mode() {
  case "$1" in
    *.sh) printf '755' ;;
    *) printf '644' ;;
  esac
}

# stage_file <source-rel> <bundle-rel> <manifest-path>: copies with an explicit
# mode and prints a "path<TAB>sha256<TAB>mode" row.
stage_file() {
  local src="$1" dst="$2" path="$3" mode sum
  mode="$(file_mode "${path}")"
  mkdir -p "$(dirname "${bundle_dir}/${dst}")"
  cp "${src_root}/${src}" "${bundle_dir}/${dst}"
  chmod "0${mode}" "${bundle_dir}/${dst}"
  sum="$(sha256sum "${bundle_dir}/${dst}" | awk '{print $1}')"
  printf '%s\t%s\t%s\n' "${path}" "${sum}" "${mode}"
}

payload_tsv=""
for f in "${PAYLOAD[@]}"; do
  payload_tsv+="$(stage_file "${f}" "payload/${f}" "${f}")"$'\n'
done
optional_tsv=""
for f in "${OPTIONAL[@]}"; do
  optional_tsv+="$(stage_file "${f}" "optional/${f}" "${f}")"$'\n'
done
support_tsv=""
for i in "${!SUPPORT_DST[@]}"; do
  support_tsv+="$(stage_file "${SUPPORT_SRC[$i]}" "${SUPPORT_DST[$i]}" "${SUPPORT_DST[$i]}")"$'\n'
done

tsv_to_json='split("\n") | map(select(length > 0) | split("\t") | {path: .[0], sha256: .[1], mode: .[2]}) | sort_by(.path)'
jq -n \
  --arg version "${version}" \
  --arg commit "${source_commit}" \
  --argjson clean "${source_tree_clean}" \
  --argjson payload "$(printf '%s' "${payload_tsv}" | jq -R -s "${tsv_to_json}")" \
  --argjson optional "$(printf '%s' "${optional_tsv}" | jq -R -s "${tsv_to_json}")" \
  --argjson support "$(printf '%s' "${support_tsv}" | jq -R -s "${tsv_to_json}")" \
  '{
    schema_version: 1,
    bundle_version: $version,
    source_commit: $commit,
    source_tree_clean: $clean,
    min_just: "1.27.0",
    payload: $payload,
    optional: $optional,
    support: $support
  }' > "${bundle_dir}/BUNDLE.json"
chmod 0644 "${bundle_dir}/BUNDLE.json"
find "${bundle_dir}" -type d -exec chmod 0755 {} +

tmp_archive="${out_dir}/.${bundle_name}.tar.gz.tmp.$$"
tar --sort=name --mtime="@${epoch}" --owner=0 --group=0 --numeric-owner \
  -C "${stage}" -cf - "${bundle_name}" | gzip -n > "${tmp_archive}"
mv "${tmp_archive}" "${archive}"

printf '%s\n' "${archive}"
