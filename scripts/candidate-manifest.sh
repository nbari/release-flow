#!/usr/bin/env bash
# Generate candidate artifact manifest and checksums.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: candidate-manifest.sh \
  --dir <path> \
  --inventory <path> \
  --project <name> \
  --repository <owner/repo> \
  --version <X.Y.Z> \
  --mode <production|test-only> \
  --base-branch <branch> \
  --base-commit <sha> \
  --candidate-branch <branch> \
  --candidate-commit <sha> \
  --run-id <id> \
  --run-attempt <num> \
  --source-date-epoch <num> \
  --adapter <path>
EOF
  exit 2
}

dir=""
inventory=""
project=""
repository=""
version=""
mode=""
base_branch=""
base_commit=""
candidate_branch=""
candidate_commit=""
run_id=""
run_attempt=""
source_date_epoch=""
adapter=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --inventory) inventory="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --repository) repository="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --base-branch) base_branch="$2"; shift 2 ;;
    --base-commit) base_commit="$2"; shift 2 ;;
    --candidate-branch) candidate_branch="$2"; shift 2 ;;
    --candidate-commit) candidate_commit="$2"; shift 2 ;;
    --run-id) run_id="$2"; shift 2 ;;
    --run-attempt) run_attempt="$2"; shift 2 ;;
    --source-date-epoch) source_date_epoch="$2"; shift 2 ;;
    --adapter) adapter="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ -z "${dir}" || -z "${inventory}" || -z "${project}" || -z "${repository}" || \
      -z "${version}" || -z "${mode}" || -z "${base_branch}" || -z "${base_commit}" || \
      -z "${candidate_branch}" || -z "${candidate_commit}" || -z "${run_id}" || \
      -z "${run_attempt}" || -z "${source_date_epoch}" || -z "${adapter}" ]]; then
  usage
fi

if [[ ! -d "${dir}" ]]; then
  echo "Directory does not exist: ${dir}" >&2
  exit 1
fi

if [[ -f "${dir}/manifest.json" || -f "${dir}/SHA256SUMS" ]]; then
  echo "manifest.json or SHA256SUMS already exists in ${dir}" >&2
  exit 1
fi

# Directory must contain only regular files
if [[ -n "$(find "${dir}" -mindepth 1 \( -type l -o ! -type f \))" ]]; then
  echo "Directory contains non-regular files or symlinks: ${dir}" >&2
  exit 1
fi

# Parse inventory
if [[ ! -f "${inventory}" ]]; then
  echo "Inventory file missing: ${inventory}" >&2
  exit 1
fi

inv_names="$(jq -er '.artifacts[]?.name // empty' "${inventory}" 2>/dev/null || true)"
if [[ -z "${inv_names}" ]]; then
  echo "Inventory has no artifacts or is invalid JSON" >&2
  exit 1
fi

# Check for duplicate artifact names in inventory
dup_check="$(printf '%s\n' "${inv_names}" | sort | uniq -d || true)"
if [[ -n "${dup_check}" ]]; then
  echo "Duplicate artifact names in inventory: ${dup_check}" >&2
  exit 1
fi

# Check validity of artifact names
for name in ${inv_names}; do
  if [[ "${name}" == "manifest.json" || "${name}" == "SHA256SUMS" ]]; then
    echo "Reserved artifact name not allowed: ${name}" >&2
    exit 1
  fi
  if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    echo "Invalid artifact name: ${name}" >&2
    exit 1
  fi
done

# Compare inventory names against files present in directory
dir_files="$(find "${dir}" -maxdepth 1 -type f -exec basename {} \; | sort)"
inv_sorted="$(printf '%s\n' "${inv_names}" | sort)"

missing_files="$(comm -23 <(printf '%s\n' "${inv_sorted}") <(printf '%s\n' "${dir_files}"))"
extra_files="$(comm -13 <(printf '%s\n' "${inv_sorted}") <(printf '%s\n' "${dir_files}"))"

if [[ -n "${missing_files}" ]]; then
  echo "Missing artifact file(s): ${missing_files}" >&2
  exit 1
fi

if [[ -n "${extra_files}" ]]; then
  echo "Unexpected file(s) in artifact directory: ${extra_files}" >&2
  exit 1
fi

# Extract build_info.tools from inventory
tools_json="$(jq '.build_info.tools // {}' "${inventory}")"

# Compute sizes and digests
artifacts_json="[]"
sums_file="${dir}/SHA256SUMS"
: > "${sums_file}"

while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  target="$(jq -er --arg n "${name}" '.artifacts[] | select(.name == $n) | .target' "${inventory}")"
  file_path="${dir}/${name}"
  file_size="$(wc -c < "${file_path}" | tr -d ' ')"
  file_sha="$(sha256sum "${file_path}" | awk '{print $1}')"

  printf '%s  %s\n' "${file_sha}" "${name}" >> "${sums_file}"

  entry="$(jq -n --arg name "${name}" --arg target "${target}" \
    --argjson size "${file_size}" --arg sha256 "${file_sha}" \
    '{name: $name, target: $target, size: $size, sha256: $sha256}')"
  artifacts_json="$(jq --argjson e "${entry}" '. += [$e]' <<< "${artifacts_json}")"
done <<< "${inv_sorted}"

# Sort SHA256SUMS deterministically
sort -k2,2 "${sums_file}" -o "${sums_file}"

# Build manifest.json in exact C4 key order
manifest_path="${dir}/manifest.json"
jq -n \
  --argjson schema_version 1 \
  --arg project "${project}" \
  --arg repository "${repository}" \
  --arg version "${version}" \
  --arg mode "${mode}" \
  --arg base_branch "${base_branch}" \
  --arg base_commit "${base_commit}" \
  --arg candidate_branch "${candidate_branch}" \
  --arg candidate_commit "${candidate_commit}" \
  --arg run_id "${run_id}" \
  --argjson run_attempt "${run_attempt}" \
  --arg adapter "${adapter}" \
  --argjson source_date_epoch "${source_date_epoch}" \
  --argjson tools "${tools_json}" \
  --argjson artifacts "${artifacts_json}" \
  '{
    schema_version: $schema_version,
    project: $project,
    repository: $repository,
    version: $version,
    mode: $mode,
    base_branch: $base_branch,
    base_commit: $base_commit,
    candidate_branch: $candidate_branch,
    candidate_commit: $candidate_commit,
    run_id: $run_id,
    run_attempt: $run_attempt,
    build_info: {
      adapter: $adapter,
      source_date_epoch: $source_date_epoch,
      tools: $tools
    },
    artifacts: $artifacts
  }' > "${manifest_path}"

# Output only manifest.json's sha256 hash on stdout
manifest_sha="$(sha256sum "${manifest_path}" | awk '{print $1}')"
printf '%s\n' "${manifest_sha}"
