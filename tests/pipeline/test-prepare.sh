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
assert_eq "0" "$(printf '%s\n' "${T_OUT}" | grep -cvE '^[a-z_]+=' || true)" "P1: every stdout line is key=value"

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
assert_eq "0" "$(printf '%s\n' "${T_OUT}" | grep -cvE '^[a-z_]+=' || true)" "P2: every stdout line is key=value (no push porcelain)"

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

t_case "P12: Interrupt signal (SIGTERM) cleanup"
repo="$(tf_fixture_repo "prepare-sigterm")"
cd "${repo}"
STUB_FAULT=sigterm t_run_group bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc nonzero "P12: interrupted run exits non-zero"
wt_count="$(git worktree list --porcelain | grep -c '^worktree ')"
assert_eq "1" "${wt_count}" "P12: worktree cleaned up after SIGTERM"
branch_count="$(git branch --list 'release/*' | wc -l)"
assert_eq "0" "${branch_count}" "P12: no branch created after SIGTERM"
cd "${orig_dir}"

t_case "P13: Adapter noop failure detection"
repo="$(tf_fixture_repo "prepare-noop")"
cd "${repo}"
STUB_FAULT=noop t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P13: rejected noop adapter"
assert_contains "${T_ERR}" "Adapter failed to apply version" "P13: detects unchanged version"
cd "${orig_dir}"

t_case "P14: Adapter undeclared changes detection"
repo="$(tf_fixture_repo "prepare-undeclared")"
cd "${repo}"
STUB_FAULT=undeclared t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P14: rejected undeclared adapter changes"
assert_contains "${T_ERR}" "Adapter changed undeclared files" "P14: detects stray files"
cd "${orig_dir}"

t_case "P15: Repeated preparation of the same version"
repo="$(tf_fixture_repo "prepare-repeat")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 0 "P15: first prepare succeeded"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P15: repeated prepare rejected"
assert_contains "${T_ERR}" "Branch collision" "P15: rejects branch collision on repeated prepare"
cd "${orig_dir}"

t_case "P16: Concurrent candidate attempts"
repo="$(tf_fixture_repo "prepare-concurrent")"
cd "${repo}"
git_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
wt_root="${git_dir}/release-flow/worktrees"
mkdir -p "${wt_root}/.prepare.lock"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch
assert_rc 1 "P16: rejected concurrent prepare attempt"
assert_contains "${T_ERR}" "Concurrent candidate preparation in progress" "P16: names concurrency lock"
rmdir "${wt_root}/.prepare.lock"
cd "${orig_dir}"

t_case "P17: Expected base commit validation"
repo="$(tf_fixture_repo "prepare-expect-base")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode test-only --expect-base-commit zzz
assert_rc 2 "P17: malformed --expect-base-commit is a usage error"
assert_eq "absent" "$(test -e "$(git rev-parse --path-format=absolute --git-common-dir)/release-flow" && echo present || echo absent)" \
  "P17: usage error runs before any Git state is created"
git checkout main --quiet
main_sha="$(git rev-parse HEAD)"
git checkout sandbox --quiet
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode test-only --expect-base-commit "${main_sha}"
assert_rc 1 "P17: mismatched expected base rejected"
assert_contains "${T_ERR}" "Base mismatch" "P17: names base mismatch"
assert_eq "0" "$(git for-each-ref refs/heads/release | wc -l | tr -d ' ')" "P17: no candidate branch created"
assert_eq "" "$(git ls-remote --heads origin 'refs/heads/release/*')" "P17: nothing pushed"
sandbox_sha="$(git rev-parse HEAD)"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode test-only --expect-base-commit "${sandbox_sha}"
assert_rc 0 "P17: matching expected base accepted"
cd "${orig_dir}"

t_case "P18: Lock released after early failure"
repo="$(tf_fixture_repo "prepare-lock-release")"
cd "${repo}"
git checkout develop --quiet
echo "unpushed develop work" >> README.md
git commit -am "Local develop commit" --quiet
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
assert_rc 1 "P18: refused when base branch has unpushed commits"
assert_contains "${T_ERR}" "has unpushed commits" "P18: explains unpushed commits"
lock_dir="$(git rev-parse --path-format=absolute --git-common-dir)/release-flow/worktrees/.prepare.lock"
assert_eq "absent" "$(test -e "${lock_dir}" && echo present || echo absent)" "P18: lock released after failure"
git push origin develop --quiet
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
assert_rc 0 "P18: retry succeeds after pushing the base"
cd "${orig_dir}"

t_finish
