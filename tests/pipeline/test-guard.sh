#!/usr/bin/env bash
# Test candidate guard checks.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

guard="${ROOT}/scripts/candidate-guard.sh"
orig_dir="$(pwd)"

t_case "G1: Valid production and test-only candidate branches"
repo="$(tf_fixture_repo "guard-test")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
assert_rc 0 "G1: prepared candidate"
cand_branch="$(printf '%s\n' "${T_OUT}" | grep '^candidate_branch=' | cut -d= -f2)"
cand_sha="$(printf '%s\n' "${T_OUT}" | grep '^candidate_commit=' | cut -d= -f2)"

git checkout "${cand_branch}" --quiet

t_run bash "${guard}" --ref "${cand_branch}" --commit "${cand_sha}"
assert_rc 0 "G1: guard accepted valid candidate"
assert_contains "${T_OUT}" "version=0.1.1" "G1: outputs version"
assert_contains "${T_OUT}" "mode=production" "G1: outputs mode"
cd "${orig_dir}"

t_case "G2: Ref not matching release/ pattern"
repo="$(tf_fixture_repo "guard-bad-ref")"
cd "${repo}"
t_run bash "${guard}" --ref "feature/something" --commit "$(git rev-parse HEAD)"
assert_rc 1 "G2: rejected non-release ref pattern"
cd "${orig_dir}"

t_case "G3: Commit mismatch"
repo="$(tf_fixture_repo "guard-commit-mismatch")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
cand_branch="$(printf '%s\n' "${T_OUT}" | grep '^candidate_branch=' | cut -d= -f2)"
git checkout "${cand_branch}" --quiet

fake_sha="2222222222222222222222222222222222222222"
t_run bash "${guard}" --ref "${cand_branch}" --commit "${fake_sha}"
assert_rc 1 "G3: rejected commit mismatch"
assert_contains "${T_ERR}" "Commit mismatch" "G3: error names commit mismatch"
cd "${orig_dir}"

t_case "G4: Extra commit on candidate branch"
repo="$(tf_fixture_repo "guard-extra-commit")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
cand_branch="$(printf '%s\n' "${T_OUT}" | grep '^candidate_branch=' | cut -d= -f2)"
git checkout "${cand_branch}" --quiet

echo "extra commit on top" >> README.md
git commit -am "Tampered commit on candidate branch" --quiet
new_sha="$(git rev-parse HEAD)"

t_run bash "${guard}" --ref "${cand_branch}" --commit "${new_sha}"
assert_rc 1 "G4: rejected extra commit on candidate branch"
cd "${orig_dir}"

t_case "G5: Conflicting tag created before guard runs"
repo="$(tf_fixture_repo "guard-tag-conflict")"
cd "${repo}"
t_run bash "${ROOT}/scripts/release-prepare.sh" patch --mode production
cand_branch="$(printf '%s\n' "${T_OUT}" | grep '^candidate_branch=' | cut -d= -f2)"
cand_sha="$(printf '%s\n' "${T_OUT}" | grep '^candidate_commit=' | cut -d= -f2)"
git checkout "${cand_branch}" --quiet

# Create tag 0.1.1
git tag "0.1.1"

t_run bash "${guard}" --ref "${cand_branch}" --commit "${cand_sha}"
assert_rc 1 "G5: rejected when tag exists"
assert_contains "${T_ERR}" "Conflicting local release tag already exists" "G5: tag collision reported"
cd "${orig_dir}"

t_finish
