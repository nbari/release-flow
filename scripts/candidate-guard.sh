#!/usr/bin/env bash
# Guard candidate branch and commit identity in CI.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: candidate-guard.sh --ref <branch-name> --commit <40-hex-sha>
EOF
  exit 2
}

ref=""
commit=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref) ref="$2"; shift 2 ;;
    --commit) commit="$2"; shift 2 ;;
    *) usage ;;
  esac
done

if [[ -z "${ref}" || -z "${commit}" ]]; then
  usage
fi

if [[ ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid commit SHA format: ${commit}" >&2
  exit 2
fi

# Strip refs/heads/ if present
branch="${ref#refs/heads/}"

# 1. Ref pattern check
if [[ "${branch}" =~ ^release/test/([0-9]+\.[0-9]+\.[0-9]+)-([0-9a-f]{12})$ ]]; then
  expected_mode="test-only"
  branch_version="${BASH_REMATCH[1]}"
  branch_base12="${BASH_REMATCH[2]}"
elif [[ "${branch}" =~ ^release/([0-9]+\.[0-9]+\.[0-9]+)-([0-9a-f]{12})$ ]]; then
  expected_mode="production"
  branch_version="${BASH_REMATCH[1]}"
  branch_base12="${BASH_REMATCH[2]}"
else
  echo "Candidate branch '${branch}' does not match release/[test/]X.Y.Z-<base12>" >&2
  exit 1
fi

# 2. Commit check
actual_head="$(git rev-parse HEAD)"
if [[ "${actual_head}" != "${commit}" ]]; then
  echo "Commit mismatch: HEAD (${actual_head}) != expected commit (${commit})" >&2
  exit 1
fi

# 3. Read configuration from current commit
if [[ ! -f .release-flow.json ]]; then
  echo "Missing .release-flow.json in candidate commit" >&2
  exit 1
fi

config_project="$(jq -er '.project // empty' .release-flow.json 2>/dev/null || true)"
config_adapter="$(jq -er '.adapter // empty' .release-flow.json 2>/dev/null || true)"
config_remote="$(jq -er '.remote // empty' .release-flow.json 2>/dev/null || true)"
config_prod_base="$(jq -er '.production_base // empty' .release-flow.json 2>/dev/null || true)"

if [[ -z "${config_project}" || -z "${config_adapter}" ]]; then
  echo "Invalid .release-flow.json (missing project or adapter)" >&2
  exit 1
fi

# Read trailers from candidate commit
trailer_proj="$(git log -1 --format='%(trailers:key=Release-Project,valueonly)' HEAD | tr -d ' ')"
trailer_ver="$(git log -1 --format='%(trailers:key=Release-Version,valueonly)' HEAD | tr -d ' ')"
trailer_mode="$(git log -1 --format='%(trailers:key=Release-Mode,valueonly)' HEAD | tr -d ' ')"
trailer_base_branch="$(git log -1 --format='%(trailers:key=Release-Base-Branch,valueonly)' HEAD | tr -d ' ')"
trailer_base_commit="$(git log -1 --format='%(trailers:key=Release-Base-Commit,valueonly)' HEAD | tr -d ' ')"

if [[ -z "${trailer_proj}" || -z "${trailer_ver}" || -z "${trailer_mode}" || \
      -z "${trailer_base_branch}" || -z "${trailer_base_commit}" ]]; then
  echo "Candidate commit is missing required Release-* trailers" >&2
  exit 1
fi

if [[ "${trailer_proj}" != "${config_project}" ]]; then
  echo "Trailer project '${trailer_proj}' does not match config project '${config_project}'" >&2
  exit 1
fi

if [[ "${trailer_ver}" != "${branch_version}" ]]; then
  echo "Trailer version '${trailer_ver}' does not match branch version '${branch_version}'" >&2
  exit 1
fi

if [[ "${trailer_mode}" != "${expected_mode}" ]]; then
  echo "Trailer mode '${trailer_mode}' does not match branch mode '${expected_mode}'" >&2
  exit 1
fi

if [[ ! "${trailer_base_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Trailer base commit '${trailer_base_commit}' is not a 40-character hex SHA" >&2
  exit 1
fi

if [[ "${trailer_base_commit:0:12}" != "${branch_base12}" ]]; then
  echo "Trailer base commit prefix '${trailer_base_commit:0:12}' does not match branch base12 '${branch_base12}'" >&2
  exit 1
fi

# 4. Topology and parent check
if git rev-parse --verify HEAD^2 >/dev/null 2>&1; then
  echo "Candidate commit is a merge commit (must have exactly one parent)" >&2
  exit 1
fi

parent_commit="$(git rev-parse HEAD^1 2>/dev/null || true)"
if [[ -z "${parent_commit}" ]]; then
  echo "Candidate commit has no parent" >&2
  exit 1
fi

if [[ "${parent_commit}" != "${trailer_base_commit}" ]]; then
  echo "Candidate commit parent ${parent_commit} does not match base commit ${trailer_base_commit}" >&2
  exit 1
fi

if git diff --quiet HEAD^1 HEAD; then
  echo "Candidate commit introduced no changes compared to its base commit" >&2
  exit 1
fi

# 5. Adapter version validation
if [[ ! -x "${config_adapter}" ]]; then
  echo "Adapter '${config_adapter}' is not executable" >&2
  exit 1
fi

adapter_ver="$( "./${config_adapter}" version )"
if [[ "${adapter_ver}" != "${branch_version}" ]]; then
  echo "Adapter version '${adapter_ver}' does not match candidate version '${branch_version}'" >&2
  exit 1
fi

# 6. Base branch ancestry validation
if [[ "${expected_mode}" == "production" ]]; then
  if [[ "${trailer_base_branch}" != "${config_prod_base}" ]]; then
    echo "Production candidate base branch '${trailer_base_branch}' does not match config production_base '${config_prod_base}'" >&2
    exit 1
  fi
  if ! git rev-parse --verify "refs/remotes/${config_remote}/${config_prod_base}" >/dev/null 2>&1; then
    echo "Remote tracking ref 'refs/remotes/${config_remote}/${config_prod_base}' not found" >&2
    exit 1
  fi
  if ! git merge-base --is-ancestor "${trailer_base_commit}" "refs/remotes/${config_remote}/${config_prod_base}"; then
    echo "Base commit ${trailer_base_commit} is not an ancestor of ${config_remote}/${config_prod_base}" >&2
    exit 1
  fi
else
  # Test-only mode: warn if base is not an ancestor
  if git rev-parse --verify "refs/remotes/${config_remote}/${trailer_base_branch}" >/dev/null 2>&1; then
    if ! git merge-base --is-ancestor "${trailer_base_commit}" "refs/remotes/${config_remote}/${trailer_base_branch}"; then
      echo "::warning::Test-only candidate base ${trailer_base_commit} is not an ancestor of ${config_remote}/${trailer_base_branch}" >&2
    fi
  fi
fi

# 7. Release tag collision check (local and remote)
if git rev-parse --verify "refs/tags/${branch_version}" >/dev/null 2>&1 || \
   git rev-parse --verify "refs/tags/v${branch_version}" >/dev/null 2>&1; then
  echo "Conflicting local release tag already exists for version ${branch_version}" >&2
  exit 1
fi

if remote_tags="$(git ls-remote --tags --refs "${config_remote}" 2>/dev/null)"; then
  if printf '%s\n' "${remote_tags}" | awk '{print $2}' | grep -qE "refs/tags/(v)?${branch_version}$"; then
    echo "Conflicting remote release tag already exists on '${config_remote}' for version ${branch_version}" >&2
    exit 1
  fi
fi

# Output key=value lines
cat <<EOF
project=${config_project}
version=${branch_version}
mode=${expected_mode}
base_branch=${trailer_base_branch}
base_commit=${trailer_base_commit}
candidate_branch=${branch}
adapter=${config_adapter}
EOF
