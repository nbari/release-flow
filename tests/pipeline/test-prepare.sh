#!/usr/bin/env bash
# Test candidate preparation failure modes and invariants.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

orig_dir="$(pwd)"

t_case "P1: Production candidate preparation in isolated worktree"
repo="$(tf_fixture_repo "prepare-prod")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
assert_rc 0 "P1: prepare patch succeeded"
assert_contains "${T_OUT}" "version=0.1.1" "P1: version is 0.1.1"
assert_contains "${T_OUT}" "mode=production" "P1: mode is production"
assert_contains "${T_OUT}" "pushed=false" "P1: pushed is false"

# Verify git state
base_sha="$(git rev-parse refs/remotes/origin/develop)"
base12="${base_sha:0:12}"
expected_branch="release/0.1.1-${base12}"
cand_sha="$(git rev-parse "refs/heads/${expected_branch}")"
parent_sha="$(git rev-parse "${cand_sha}^1")"
assert_eq "${base_sha}" "${parent_sha}" "P1: candidate parent is base develop"

# Trailed release metadata
trailer_ver="$(git log -1 --format='%(trailers:key=Release-Version,valueonly)' "${cand_sha}" | tr -d ' ')"
assert_eq "0.1.1" "${trailer_ver}" "P1: trailer version is 0.1.1"

# Assert no worktree left behind
wt_count="$(git worktree list --porcelain | grep -c '^worktree ')"
assert_eq "1" "${wt_count}" "P1: no extra worktrees left"
cd "${orig_dir}"

t_case "P2: Test-only candidate with push"
repo="$(tf_fixture_repo "prepare-test")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" minor --mode test-only --push
assert_rc 0 "P2: test-only prepare succeeded"
assert_contains "${T_OUT}" "version=0.2.0" "P2: version is 0.2.0"
assert_contains "${T_OUT}" "mode=test-only" "P2: mode is test-only"
assert_contains "${T_OUT}" "pushed=true" "P2: pushed is true"

base_sha="$(git rev-parse refs/remotes/origin/sandbox)"
base12="${base_sha:0:12}"
expected_branch="release/test/0.2.0-${base12}"
# Check that branch was pushed to origin
remote_sha="$(git ls-remote origin "refs/heads/${expected_branch}" | awk '{print $1}')"
local_sha="$(git rev-parse "refs/heads/${expected_branch}")"
assert_eq "${local_sha}" "${remote_sha}" "P2: branch exists on remote origin"
cd "${orig_dir}"

t_case "P3: Dirty working tree rejection"
repo="$(tf_fixture_repo "prepare-dirty")"
cd "${repo}"
echo "dirty modification" >> README.md
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P3: refused dirty working tree"
assert_contains "${T_ERR}" "Working tree is dirty" "P3: error message explains dirty tree"
cd "${orig_dir}"

t_case "P4: Invalid bump token or non-SemVer version"
repo="$(tf_fixture_repo "prepare-invalid-token")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" invalid-token
assert_rc 2 "P4: refused invalid token"
t_run bash "${ROOT}/scripts/release-prepare.sh" 0.1
assert_rc 2 "P4: refused two-part version"
t_run bash "${ROOT}/scripts/release-prepare.sh" 0.0.9
assert_rc 1 "P4: refused lower explicit version"
cd "${orig_dir}"

t_case "P5: Tag collision rejection"
repo="$(tf_fixture_repo "prepare-tag-collision")"
cd "${repo}"
git tag 0.1.1
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P5: refused on local tag collision"
assert_contains "${T_ERR}" "Tag collision" "P5: tag collision error reported"
cd "${orig_dir}"

t_case "P6: Branch collision rejection"
repo="$(tf_fixture_repo "prepare-branch-collision")"
cd "${repo}"
base_sha="$(git rev-parse refs/remotes/origin/develop)"
base12="${base_sha:0:12}"
git branch "release/0.1.1-${base12}" HEAD
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P6: refused on branch collision"
assert_contains "${T_ERR}" "Branch collision" "P6: branch collision reported"
cd "${orig_dir}"

t_case "P7: Production mode with non-production base rejection"
repo="$(tf_fixture_repo "prepare-prod-base")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production --base sandbox
assert_rc 2 "P7: rejected invalid base override in production mode"
cd "${orig_dir}"

t_case "P8: Unpushed base branch rejection"
repo="$(tf_fixture_repo "prepare-unpushed-base")"
cd "${repo}"
git checkout develop --quiet
echo "unpushed develop work" >> README.md
git commit -am "Local develop commit" --quiet
git checkout sandbox --quiet
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
assert_rc 1 "P8: refused when base branch has unpushed commits"
assert_contains "${T_ERR}" "has unpushed commits" "P8: explains unpushed commits"
cd "${orig_dir}"

t_case "P9: Adapter failure cleanup"
repo="$(tf_fixture_repo "prepare-adapter-fail")"
cd "${repo}"
# Inject adapter failure on develop branch
git checkout develop --quiet
git commit --allow-empty -m "Inject fault" --quiet
git push origin develop --quiet
git checkout sandbox --quiet

STUB_FAULT=set-version-fail t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
assert_rc 1 "P9: refused on adapter set-version failure"
# Assert worktree cleaned up and no branch created
wt_count="$(git worktree list --porcelain | grep -c '^worktree ')"
assert_eq "1" "${wt_count}" "P9: worktree cleaned up on error"
branch_count="$(git branch --list 'release/*' | wc -l)"
assert_eq "0" "${branch_count}" "P9: no release branch created"
cd "${orig_dir}"

t_case "P10: Stale worktree detection"
repo="$(tf_fixture_repo "prepare-stale-wt")"
cd "${repo}"
git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
wt_root="${git_dir}/release-flow/worktrees"
mkdir -p "${wt_root}"
stale_wt="$(mktemp -d "${wt_root}/wt.staleXXXX")"
git worktree add --detach --quiet "${stale_wt}" HEAD

t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P10: detected existing worktree"
assert_contains "${T_ERR}" "Existing active or stale candidate worktree" "P10: error message names stale worktree"

# Clean up stale worktree
git worktree remove --force "${stale_wt}"
git worktree prune
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 0 "P10: succeeded after cleaning stale worktree"
cd "${orig_dir}"

t_case "P11: Remote push rejection handling"
repo="$(tf_fixture_repo "prepare-push-reject")"
cd "${repo}"
bare_dir="${TF_TMP}/prepare-push-reject.git"
cat <<'EOF' > "${bare_dir}/hooks/pre-receive"
#!/usr/bin/env bash
while read -r old new ref; do
  if [[ "${ref}" == refs/heads/release/* ]]; then
    echo "Simulated server rejection of release branch" >&2
    exit 1
  fi
done
EOF
chmod +x "${bare_dir}/hooks/pre-receive"

t_run bash "${ROOT}/scripts/release-prepare.sh" patch --push
assert_rc 1 "P11: prepare failed when push was rejected"
assert_contains "${T_ERR}" "Push failed" "P11: push failure reported"
# Assert local branch was preserved for recovery
branch_count="$(git branch --list 'release/*' | wc -l)"
assert_eq "1" "${branch_count}" "P11: local candidate branch preserved"
cd "${orig_dir}"

t_finish
