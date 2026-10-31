#!/usr/bin/env bash
# Independent verifier for candidate artifacts and manifest.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: verify-candidate.sh --dir <dir> --commit <expected-commit-sha> [OPTIONS]

Required:
  --dir <path>                   Directory containing candidate artifacts
  --commit <40-hex>              Expected candidate commit SHA

Optional verification filters:
  --version <X.Y.Z>              Expected release version
  --mode <production|test-only>  Expected candidate mode
  --base-commit <40-hex>         Expected base commit SHA
  --project <name>               Expected project name
  --repository <owner/repo>      Expected repository
  --run-id <id>                  Expected CI run ID
  --manifest-sha256 <64-hex>     Pinned SHA-256 of manifest.json
EOF
  exit 2
}

dir=""
expected_commit=""
expected_version=""
expected_mode=""
expected_base_commit=""
expected_project=""
expected_repository=""
expected_run_id=""
expected_manifest_sha=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) dir="$2"; shift 2 ;;
    --commit) expected_commit="$2"; shift 2 ;;
    --version) expected_version="$2"; shift 2 ;;
    --mode) expected_mode="$2"; shift 2 ;;
    --base-commit) expected_base_commit="$2"; shift 2 ;;
    --project) expected_project="$2"; shift 2 ;;
    --repository) expected_repository="$2"; shift 2 ;;
    --run-id) expected_run_id="$2"; shift 2 ;;
    --manifest-sha256) expected_manifest_sha="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ -z "${dir}" || -z "${expected_commit}" ]]; then
  usage
fi

if [[ ! "${expected_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid expected commit SHA format: ${expected_commit}" >&2
  exit 2
fi

failures=()

fail() {
  failures+=("$1")
}

# 1. Directory check
if [[ ! -d "${dir}" ]]; then
  fail "Directory does not exist: ${dir}"
  for f in "${failures[@]}"; do echo "FAIL: ${f}" >&2; done
  exit 1
fi

non_regular="$(find "${dir}" -mindepth 1 \( -type l -o ! -type f \) || true)"
if [[ -n "${non_regular}" ]]; then
  fail "Artifact directory contains non-regular files, directories, or symlinks"
fi

# 2. Control files exist
manifest_file="${dir}/manifest.json"
sums_file="${dir}/SHA256SUMS"

if [[ ! -f "${manifest_file}" ]]; then
  fail "Missing manifest.json"
fi

if [[ ! -f "${sums_file}" ]]; then
  fail "Missing SHA256SUMS"
fi

# If control files are missing, fail immediately
if (( ${#failures[@]} > 0 )); then
  for f in "${failures[@]}"; do echo "FAIL: ${f}" >&2; done
  exit 1
fi

# 3. Check pinned manifest sha256 if given
actual_manifest_sha="$(sha256sum "${manifest_file}" | awk '{print $1}')"
if [[ -n "${expected_manifest_sha}" ]]; then
  if [[ "${actual_manifest_sha}" != "${expected_manifest_sha}" ]]; then
    fail "Pinned manifest SHA256 mismatch (expected: ${expected_manifest_sha}, actual: ${actual_manifest_sha})"
  fi
fi

# 4. JSON schema validation via jq
schema_errors="$(jq -r '
  def err(m): "schema error: " + m;
  [
    (if .schema_version != 1 then err("schema_version must be 1") else empty end),
    (if (.project | type) != "string" or (.project | test("^[A-Za-z0-9][A-Za-z0-9._-]*$") | not) then err("invalid project") else empty end),
    (if (.repository | type) != "string" or (.repository | test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") | not) then err("invalid repository") else empty end),
    (if (.version | type) != "string" or (.version | test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$") | not) then err("invalid version") else empty end),
    (if .mode != "production" and .mode != "test-only" then err("mode must be production or test-only") else empty end),
    (if (.base_branch | type) != "string" or (.base_branch | length) == 0 then err("invalid base_branch") else empty end),
    (if (.base_commit | type) != "string" or (.base_commit | test("^[0-9a-f]{40}$") | not) then err("invalid base_commit") else empty end),
    (if (.candidate_branch | type) != "string" or (.candidate_branch | length) == 0 then err("invalid candidate_branch") else empty end),
    (if (.candidate_commit | type) != "string" or (.candidate_commit | test("^[0-9a-f]{40}$") | not) then err("invalid candidate_commit") else empty end),
    (if (.run_id | type) != "string" or (.run_id | test("^[0-9]+$") | not) then err("invalid run_id") else empty end),
    (if (.run_attempt | type) != "number" or .run_attempt < 1 then err("invalid run_attempt") else empty end),
    (if (.build_info | type) != "object" then err("build_info must be object")
     elif (.build_info.adapter | type) != "string" then err("build_info.adapter must be string")
     elif (.build_info.source_date_epoch | type) != "number" or .build_info.source_date_epoch < 0 then err("invalid source_date_epoch")
     elif (.build_info.tools | type) != "object" then err("build_info.tools must be object")
     else empty end),
    (if (.artifacts | type) != "array" or (.artifacts | length) == 0 then err("artifacts must be non-empty array")
     elif ([.artifacts[].name] | length) != ([.artifacts[].name] | unique | length) then err("duplicate artifact names")
     else empty end),
    (.artifacts[]? |
      (if (.name | type) != "string" or (.name | test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") | not) or .name == "manifest.json" or .name == "SHA256SUMS" then err("invalid artifact name: " + (.name|tostring)) else empty end),
      (if (.target | type) != "string" or (.target | test("^[A-Za-z0-9._+-]+$") | not) then err("invalid artifact target: " + (.target|tostring)) else empty end),
      (if (.size | type) != "number" or .size < 0 then err("invalid artifact size: " + (.size|tostring)) else empty end),
      (if (.sha256 | type) != "string" or (.sha256 | test("^[0-9a-f]{64}$") | not) then err("invalid artifact sha256: " + (.sha256|tostring)) else empty end)
    )
  ] | .[]
' "${manifest_file}" 2>/dev/null || echo "schema error: malformed JSON")"

if [[ -n "${schema_errors}" ]]; then
  while IFS= read -r err_line; do
    [[ -n "${err_line}" ]] && fail "${err_line}"
  done <<< "${schema_errors}"
fi

# Top-level exact keys check
allowed_keys="schema_version project repository version mode base_branch base_commit candidate_branch candidate_commit run_id run_attempt build_info artifacts"
actual_keys="$(jq -r 'keys | sort | join(" ")' "${manifest_file}" 2>/dev/null || true)"
expected_keys_sorted="$(printf '%s\n' ${allowed_keys} | sort | tr '\n' ' ' | sed 's/ $//')"
if [[ "${actual_keys}" != "${expected_keys_sorted}" ]]; then
  fail "Manifest contains unexpected or missing top-level keys"
fi

# 5. Identity checks
cand_commit="$(jq -r '.candidate_commit // empty' "${manifest_file}")"
if [[ "${cand_commit}" != "${expected_commit}" ]]; then
  fail "Candidate commit mismatch (manifest: ${cand_commit}, expected: ${expected_commit})"
fi

if [[ -n "${expected_version}" ]]; then
  man_version="$(jq -r '.version // empty' "${manifest_file}")"
  if [[ "${man_version}" != "${expected_version}" ]]; then
    fail "Version mismatch (manifest: ${man_version}, expected: ${expected_version})"
  fi
fi

if [[ -n "${expected_mode}" ]]; then
  man_mode="$(jq -r '.mode // empty' "${manifest_file}")"
  if [[ "${man_mode}" != "${expected_mode}" ]]; then
    fail "Mode mismatch (manifest: ${man_mode}, expected: ${expected_mode})"
  fi
fi

if [[ -n "${expected_base_commit}" ]]; then
  man_base="$(jq -r '.base_commit // empty' "${manifest_file}")"
  if [[ "${man_base}" != "${expected_base_commit}" ]]; then
    fail "Base commit mismatch (manifest: ${man_base}, expected: ${expected_base_commit})"
  fi
fi

if [[ -n "${expected_project}" ]]; then
  man_proj="$(jq -r '.project // empty' "${manifest_file}")"
  if [[ "${man_proj}" != "${expected_project}" ]]; then
    fail "Project mismatch (manifest: ${man_proj}, expected: ${expected_project})"
  fi
fi

if [[ -n "${expected_repository}" ]]; then
  man_repo="$(jq -r '.repository // empty' "${manifest_file}")"
  if [[ "${man_repo}" != "${expected_repository}" ]]; then
    fail "Repository mismatch (manifest: ${man_repo}, expected: ${expected_repository})"
  fi
fi

if [[ -n "${expected_run_id}" ]]; then
  man_run_id="$(jq -r '.run_id // empty' "${manifest_file}")"
  if [[ "${man_run_id}" != "${expected_run_id}" ]]; then
    fail "Run ID mismatch (manifest: ${man_run_id}, expected: ${expected_run_id})"
  fi
fi

# 6. Inventory check (directory contents vs manifest artifact names)
dir_files="$(find "${dir}" -maxdepth 1 -type f -exec basename {} \; | grep -vE '^(manifest\.json|SHA256SUMS)$' | sort)"
manifest_artifacts="$(jq -r '.artifacts[]?.name // empty' "${manifest_file}" | sort)"

missing_artifacts="$(comm -23 <(printf '%s\n' "${manifest_artifacts}") <(printf '%s\n' "${dir_files}"))"
extra_artifacts="$(comm -13 <(printf '%s\n' "${manifest_artifacts}") <(printf '%s\n' "${dir_files}"))"

if [[ -n "${missing_artifacts}" ]]; then
  fail "Missing artifact file(s): ${missing_artifacts}"
fi
if [[ -n "${extra_artifacts}" ]]; then
  fail "Unexpected file(s) in candidate directory: ${extra_artifacts}"
fi

# 7. Check SHA256SUMS syntax, uniqueness, and consistency with manifest
sums_names="$(awk '{print $2}' "${sums_file}" | sort)"
sums_dups="$(printf '%s\n' "${sums_names}" | uniq -d || true)"
if [[ -n "${sums_dups}" ]]; then
  fail "Duplicate entries in SHA256SUMS: ${sums_dups}"
fi

if [[ "${sums_names}" != "${manifest_artifacts}" ]]; then
  fail "SHA256SUMS entries do not match manifest artifact names"
fi

while IFS= read -r line || [[ -n "${line}" ]]; do
  [[ -n "${line}" ]] || continue
  if [[ ! "${line}" =~ ^[0-9a-f]{64}[[:space:]]{2}[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
    fail "Malformed line in SHA256SUMS: ${line}"
    continue
  fi
  sha="$(awk '{print $1}' <<< "${line}")"
  name="$(awk '{print $2}' <<< "${line}")"
  man_sha="$(jq -r --arg n "${name}" '.artifacts[] | select(.name == $n) | .sha256' "${manifest_file}")"
  if [[ "${sha}" != "${man_sha}" ]]; then
    fail "Checksum in SHA256SUMS differs from manifest for ${name}"
  fi
done < "${sums_file}"

# 8. Check actual file bytes: sha256 and size against manifest
while IFS= read -r name; do
  [[ -n "${name}" ]] || continue
  file_path="${dir}/${name}"
  if [[ ! -f "${file_path}" ]]; then
    continue
  fi

  expected_sha="$(jq -r --arg n "${name}" '.artifacts[] | select(.name == $n) | .sha256' "${manifest_file}")"
  expected_size="$(jq -r --arg n "${name}" '.artifacts[] | select(.name == $n) | .size' "${manifest_file}")"

  actual_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
  actual_size="$(wc -c < "${file_path}" | tr -d ' ')"

  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    fail "Checksum mismatch for ${name} (manifest: ${expected_sha}, file: ${actual_sha})"
  fi
  if [[ "${actual_size}" != "${expected_size}" ]]; then
    fail "Size mismatch for ${name} (manifest: ${expected_size}, file: ${actual_size})"
  fi
done <<< "${manifest_artifacts}"

# Check failures
if (( ${#failures[@]} > 0 )); then
  for f in "${failures[@]}"; do
    echo "FAIL: ${f}" >&2
  done
  exit 1
fi

proj="$(jq -r '.project' "${manifest_file}")"
ver="$(jq -r '.version' "${manifest_file}")"
cand="$(jq -r '.candidate_commit' "${manifest_file}")"
count="$(jq -r '.artifacts | length' "${manifest_file}")"

printf 'VERIFIED %s %s %s artifacts=%s manifest_sha256=%s\n' \
  "${proj}" "${ver}" "${cand}" "${count}" "${actual_manifest_sha}"
exit 0
