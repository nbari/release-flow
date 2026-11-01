#!/usr/bin/env bash
# Prepare an isolated, versioned candidate commit in a temporary Git worktree.
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: release-prepare.sh <patch|minor|major|X.Y.Z> [--mode production|test-only] [--base <branch>] [--push] [--expect-base-commit <sha>]
EOF
  exit 2
}

if [[ $# -lt 1 ]]; then
  usage
fi

bump_token="$1"
shift

mode="production"
base_override=""
do_push=false
expect_base_commit=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || usage
      mode="$2"
      shift 2
      ;;
    --base)
      [[ $# -ge 2 ]] || usage
      base_override="$2"
      shift 2
      ;;
    --push)
      do_push=true
      shift
      ;;
    --expect-base-commit)
      [[ $# -ge 2 ]] || usage
      expect_base_commit="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

if [[ "${mode}" != "production" && "${mode}" != "test-only" ]]; then
  echo "Invalid mode: ${mode} (expected production or test-only)" >&2
  exit 2
fi

# Validate bump token
if [[ ! "${bump_token}" =~ ^(patch|minor|major|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
  echo "Invalid bump token: ${bump_token} (expected patch, minor, major, or X.Y.Z)" >&2
  exit 2
fi

if [[ -n "${expect_base_commit}" && ! "${expect_base_commit}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Invalid --expect-base-commit: ${expect_base_commit} (expected a 40-character lowercase hex commit id)" >&2
  exit 2
fi

top_dir="$(git rev-parse --show-toplevel)"
cd "${top_dir}"

# 1. Read .release-flow.json from HEAD
config_json="$(git show HEAD:.release-flow.json 2>/dev/null || true)"
if [[ -z "${config_json}" ]]; then
  echo "Missing or uncommitted .release-flow.json at HEAD" >&2
  exit 1
fi

schema_ver="$(printf '%s' "${config_json}" | jq -er '.schema_version // empty')"
if [[ "${schema_ver}" != "1" ]]; then
  echo "Unsupported schema_version in .release-flow.json: ${schema_ver}" >&2
  exit 1
fi

cfg_remote="$(printf '%s' "${config_json}" | jq -er '.remote // empty')"
cfg_prod_base="$(printf '%s' "${config_json}" | jq -er '.production_base // empty')"
cfg_test_base="$(printf '%s' "${config_json}" | jq -er '.test_base // empty')"

if [[ -z "${cfg_remote}" || -z "${cfg_prod_base}" || -z "${cfg_test_base}" ]]; then
  echo "Incomplete configuration in .release-flow.json" >&2
  exit 1
fi

if [[ "${mode}" == "production" ]]; then
  if [[ -n "${base_override}" && "${base_override}" != "${cfg_prod_base}" ]]; then
    echo "Production mode requires base branch '${cfg_prod_base}', got '${base_override}'" >&2
    exit 2
  fi
  base_branch="${cfg_prod_base}"
else
  base_branch="${base_override:-${cfg_test_base}}"
fi

# 2. Check clean working tree
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  echo "Working tree is dirty. Stash or commit changes first." >&2
  exit 1
fi

# 3. Worktree root and concurrency check
git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
WT_ROOT="${RELEASE_FLOW_WORKTREE_ROOT:-${git_dir}/release-flow/worktrees}"
LOCK_DIR="${WT_ROOT}/.prepare.lock"

mkdir -p "${WT_ROOT}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  echo "Concurrent candidate preparation in progress (lock held: ${LOCK_DIR})" >&2
  exit 1
fi

# The lock is held from here on: every exit path must release it.
wt=""
cleanup() {
  if [[ -n "${wt}" && -d "${wt}" ]]; then
    git worktree remove --force "${wt}" 2>/dev/null || rm -rf "${wt}"
  fi
  git worktree prune 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git worktree prune

if git worktree list --porcelain | grep -q "^worktree ${WT_ROOT}/wt\."; then
  echo "Existing active or stale candidate worktree detected under ${WT_ROOT}." >&2
  echo "Clean up with: git worktree remove --force <path> && git worktree prune" >&2
  exit 1
fi

# 4. Resolve base ref and ensure up to date
if ! git fetch --no-tags --quiet "${cfg_remote}" "+refs/heads/${base_branch}:refs/remotes/${cfg_remote}/${base_branch}"; then
  echo "Failed to fetch base branch '${base_branch}' from remote '${cfg_remote}'" >&2
  exit 1
fi

base_sha="$(git rev-parse --verify "refs/remotes/${cfg_remote}/${base_branch}^{commit}" 2>/dev/null || true)"
if [[ -z "${base_sha}" ]]; then
  echo "Failed to resolve commit for base branch refs/remotes/${cfg_remote}/${base_branch}" >&2
  exit 1
fi

if git rev-parse --verify "refs/heads/${base_branch}" >/dev/null 2>&1; then
  if ! git merge-base --is-ancestor "refs/heads/${base_branch}" "${base_sha}"; then
    echo "Local branch '${base_branch}' has unpushed commits not present on '${cfg_remote}/${base_branch}'. Push '${base_branch}' first." >&2
    exit 1
  fi
fi

if [[ -n "${expect_base_commit}" && "${base_sha}" != "${expect_base_commit}" ]]; then
  echo "Base mismatch: local HEAD ${expect_base_commit:0:12} is not ${cfg_remote}/${base_branch} (${base_sha:0:12}). Pull or rebase onto ${cfg_remote}/${base_branch}, push, then retry." >&2
  exit 1
fi

# 5. Remote state check
if ! remote_tags="$(git ls-remote --tags --refs "${cfg_remote}")"; then
  echo "Failed to query remote tags from '${cfg_remote}'" >&2
  exit 1
fi
if ! remote_heads="$(git ls-remote --heads "${cfg_remote}")"; then
  echo "Failed to query remote heads from '${cfg_remote}'" >&2
  exit 1
fi
# 6. Worktree setup (cleanup trap installed when the lock was taken)
wt="$(mktemp -d "${WT_ROOT}/wt.XXXXXX")"
git -c core.hooksPath=/dev/null worktree add --detach --quiet "${wt}" "${base_sha}"

# 7. Read configuration and adapter from the base commit
if [[ ! -f "${wt}/.release-flow.json" ]]; then
  echo "Base commit ${base_sha} does not provide .release-flow.json" >&2
  exit 1
fi

base_config="$(cat "${wt}/.release-flow.json")"
project_name="$(printf '%s' "${base_config}" | jq -er '.project // empty')"
adapter_rel="$(printf '%s' "${base_config}" | jq -er '.adapter // empty')"

if [[ -z "${project_name}" || -z "${adapter_rel}" ]]; then
  echo "Base commit configuration missing project or adapter" >&2
  exit 1
fi

adapter_path="${wt}/${adapter_rel}"
if [[ ! -x "${adapter_path}" ]]; then
  echo "Adapter '${adapter_rel}' is not executable in base commit" >&2
  exit 1
fi

current_ver="$( (cd "${wt}" && "./${adapter_rel}" version) )"
if [[ ! "${current_ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid version '${current_ver}' returned by adapter in base commit" >&2
  exit 1
fi

# 8. Compute next SemVer version
next_ver=""
IFS='.' read -r cur_major cur_minor cur_patch <<< "${current_ver}"

if [[ "${bump_token}" == "patch" ]]; then
  next_ver="${cur_major}.${cur_minor}.$(( 10#${cur_patch} + 1 ))"
elif [[ "${bump_token}" == "minor" ]]; then
  next_ver="${cur_major}.$(( 10#${cur_minor} + 1 )).0"
elif [[ "${bump_token}" == "major" ]]; then
  next_ver="$(( 10#${cur_major} + 1 )).0.0"
else
  next_ver="${bump_token}"
  # Ensure explicit version is strictly greater
  IFS='.' read -r exp_major exp_minor exp_patch <<< "${next_ver}"
  if (( 10#${exp_major} < 10#${cur_major} )) || \
     (( 10#${exp_major} == 10#${cur_major} && 10#${exp_minor} < 10#${cur_minor} )) || \
     (( 10#${exp_major} == 10#${cur_major} && 10#${exp_minor} == 10#${cur_minor} && 10#${exp_patch} <= 10#${cur_patch} )); then
    echo "Explicit version ${next_ver} must be strictly greater than current version ${current_ver}" >&2
    exit 1
  fi
fi

# Check tag collisions (local and remote)
all_tags="$( (git tag -l; printf '%s\n' "${remote_tags}" | awk '{print $2}' | sed 's|^refs/tags/||') | sort -u )"
for existing_tag in ${all_tags}; do
  if [[ "${existing_tag}" == "${next_ver}" || "${existing_tag}" == "v${next_ver}" ]]; then
    echo "Tag collision: tag '${existing_tag}' already exists" >&2
    exit 1
  fi
  # If tag is stable SemVer, ensure next_ver > tag
  clean_tag="${existing_tag#v}"
  if [[ "${clean_tag}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    IFS='.' read -r t_maj t_min t_pat <<< "${clean_tag}"
    IFS='.' read -r n_maj n_min n_pat <<< "${next_ver}"
    if (( 10#${n_maj} < 10#${t_maj} )) || \
       (( 10#${n_maj} == 10#${t_maj} && 10#${n_min} < 10#${t_min} )) || \
       (( 10#${n_maj} == 10#${t_maj} && 10#${n_min} == 10#${t_min} && 10#${n_pat} <= 10#${t_pat} )); then
      echo "Version collision: next version ${next_ver} is not strictly greater than existing tag ${existing_tag}" >&2
      exit 1
    fi
  fi
done

# Build candidate branch name
base12="${base_sha:0:12}"
if [[ "${mode}" == "production" ]]; then
  candidate_branch="release/${next_ver}-${base12}"
else
  candidate_branch="release/test/${next_ver}-${base12}"
fi

if ! git check-ref-format --branch "${candidate_branch}" >/dev/null; then
  echo "Invalid branch name generated: ${candidate_branch}" >&2
  exit 1
fi

# Check branch collision (local and remote)
if git rev-parse --verify "refs/heads/${candidate_branch}" >/dev/null 2>&1; then
  echo "Branch collision: local branch '${candidate_branch}' already exists" >&2
  exit 1
fi

if printf '%s\n' "${remote_heads}" | grep -q "refs/heads/${candidate_branch}$"; then
  echo "Branch collision: remote branch '${candidate_branch}' already exists on '${cfg_remote}'" >&2
  exit 1
fi

# 9. Apply version inside worktree
changed_files="$( (cd "${wt}" && "./${adapter_rel}" set-version "${next_ver}") )"
if [[ -z "${changed_files}" ]]; then
  echo "Adapter set-version failed: reported no modified files" >&2
  exit 1
fi

verified_ver="$( (cd "${wt}" && "./${adapter_rel}" version) )"
if [[ "${verified_ver}" != "${next_ver}" ]]; then
  echo "Adapter failed to apply version: expected ${next_ver}, got ${verified_ver}" >&2
  exit 1
fi

# Check that untracked/modified files match changed_files exactly
actual_status="$(git -C "${wt}" status --porcelain --untracked-files=all | awk '{print $2}' | sort)"
declared_sorted="$(printf '%s\n' "${changed_files}" | sort)"
if [[ "${actual_status}" != "${declared_sorted}" ]]; then
  echo "Adapter changed undeclared files in worktree:" >&2
  echo "  Declared: ${declared_sorted}" >&2
  echo "  Actual:   ${actual_status}" >&2
  exit 1
fi

while IFS= read -r f; do
  [[ -n "$f" ]] && git -C "${wt}" add "$f"
done <<< "${changed_files}"

# 10. Commit inside worktree
msg_file="$(mktemp "${TF_TMP:-/tmp}/release-msg.XXXXXX")"
cat <<EOF > "${msg_file}"
release: ${project_name} ${next_ver}

Candidate prepared by release-flow. Not promoted.

Release-Project: ${project_name}
Release-Version: ${next_ver}
Release-Mode: ${mode}
Release-Base-Branch: ${base_branch}
Release-Base-Commit: ${base_sha}
EOF

git -C "${wt}" -c core.hooksPath=/dev/null commit --quiet -F "${msg_file}"
rm -f "${msg_file}"

candidate_sha="$(git -C "${wt}" rev-parse HEAD)"

# Verify commit topology
parent_sha="$(git -C "${wt}" rev-parse HEAD^1)"
if [[ "${parent_sha}" != "${base_sha}" ]]; then
  echo "Candidate commit parent ${parent_sha} does not match base ${base_sha}" >&2
  exit 1
fi

if git -C "${wt}" rev-parse --verify HEAD^2 >/dev/null 2>&1; then
  echo "Candidate commit has multiple parents (must be a single-parent commit)" >&2
  exit 1
fi

# 11. Create branch locally (create-only)
if ! git update-ref -m "release-flow: prepare candidate" "refs/heads/${candidate_branch}" "${candidate_sha}" ""; then
  echo "Failed to create local candidate branch '${candidate_branch}'" >&2
  exit 1
fi

# 12. Optional push (create-only)
pushed=false
if [[ "${do_push}" == "true" ]]; then
  # --porcelain ref status lines go to stderr: stdout carries only key=value output.
  if git push --no-follow-tags --porcelain --force-with-lease="refs/heads/${candidate_branch}:" "${cfg_remote}" "${candidate_sha}:refs/heads/${candidate_branch}" >&2; then
    pushed=true
    echo "Candidate branch pushed to ${cfg_remote}/${candidate_branch}" >&2
  else
    echo "Push failed: remote branch '${candidate_branch}' could not be created cleanly." >&2
    echo "Retry push manually: git push --no-follow-tags --force-with-lease=\"refs/heads/${candidate_branch}:\" ${cfg_remote} ${candidate_sha}:refs/heads/${candidate_branch}" >&2
    echo "Or delete local branch: git branch -D ${candidate_branch}" >&2
    exit 1
  fi
fi

# 13. Output key=value lines on stdout
cat <<EOF
project=${project_name}
version=${next_ver}
mode=${mode}
base_branch=${base_branch}
base_commit=${base_sha}
candidate_branch=${candidate_branch}
candidate_commit=${candidate_sha}
pushed=${pushed}
EOF

echo "Candidate prepared successfully: ${candidate_branch} (${candidate_sha:0:12})" >&2
if [[ "${do_push}" != "true" ]]; then
  echo "Next step (push candidate to trigger CI validation):" >&2
  echo "  git push --no-follow-tags --force-with-lease=\"refs/heads/${candidate_branch}:\" ${cfg_remote} ${candidate_sha}:refs/heads/${candidate_branch}" >&2
fi
