#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pipeline/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"
tf_forbid_toolchains
tf_mock_gh_on
repo="$(tf_release_repo candidates)"
RF_REAL_GIT="$(command -v git)"
export RF_REAL_GIT
mkdir "$TF_TMP/catalog-bin"
ln -s "$ROOT/tests/pipeline/fixtures/candidate-git.sh" "$TF_TMP/catalog-bin/git"
ln -s "$ROOT/tests/pipeline/fixtures/candidate-gh.sh" "$TF_TMP/catalog-bin/gh"
export PATH="$TF_TMP/catalog-bin:$PATH"
# shellcheck disable=SC2329 # Invoked by t_run.
catalog() { bash "$ROOT/scripts/release-candidates.sh" --project-dir "$repo" "$@"; }
runs_endpoint() { jq -rn --arg b "$1" '"repos/acme/candidates/actions/runs?branch="+($b|@uri)+"&per_page=100"'; }
record_run() {
  tf_gh_put "$(runs_endpoint "$TF_BRANCH")" "$(cat "$(tf_gh_file "repos/acme/candidates/actions/workflows/candidate.yml/runs?head_sha=$TF_C&event=push&per_page=100")")"
  tf_gh_put "repos/acme/candidates/rules/branches/$(jq -rn --arg b "$TF_BRANCH" '$b|@uri')" '[]'
}

t_case 'Empty discovery and default prune are read-only'
before="$(tf_remote_refs "$TF_TMP/candidates.git")"
t_run catalog --json
assert_rc 0 'empty catalog works'
assert_eq 0 "$(jq '.items|length' <<< "$T_OUT")" 'empty catalog'
t_run catalog --prune --apply --json
assert_rc 0 'empty apply is a no-op'
assert_eq "$before" "$(tf_remote_refs "$TF_TMP/candidates.git")" 'empty apply preserves refs'

t_case 'Unpublished production candidates require an operator decision'
tf_candidate "$repo"
prod_branch="$TF_BRANCH"; prod_commit="$TF_C"
record_run
adapter_before="$(cat "$STUB_LOG")"
before="$(tf_remote_refs "$TF_TMP/candidates.git")"
t_run catalog --json
assert_rc 0 'catalog loads real candidate identity and retention'
assert_eq success "$(jq -r '.items[0].validation.state' <<< "$T_OUT")" 'exact candidate check verified'
assert_eq retained "$(jq -r '.items[0].retention.state' <<< "$T_OUT")" 'retention record matched'
assert_eq current "$(jq -r '.items[0].base_status' <<< "$T_OUT")" 'base is current'
assert_eq false "$(jq -r '.items[0].safe_to_delete' <<< "$T_OUT")" 'unpublished version is kept'
assert_eq "$prod_commit" "$(jq -r '.items[0].commit' <<< "$T_OUT")" 'full source SHA exposed'
assert_eq "$adapter_before" "$(cat "$STUB_LOG")" 'no adapter executed'
t_run catalog --prune --json
assert_rc 0 'default prune succeeds as dry run'
assert_eq false "$(jq -r .applied <<< "$T_OUT")" 'dry run by default'
assert_eq "$before" "$(tf_remote_refs "$TF_TMP/candidates.git")" 'dry run preserves refs'

t_case 'Completed test candidates are eligible, active and protected ones are not'
tf_candidate "$repo" patch --from sandbox
test_branch="$TF_BRANCH"; test_commit="$TF_C"
record_run
t_run catalog --json
assert_rc 0 'test candidate discovered'
assert_eq true "$(jq -r --arg b "$test_branch" '.items[]|select(.branch==$b)|.safe_to_delete' <<< "$T_OUT")" 'completed test candidate is eligible'
endpoint="$(runs_endpoint "$test_branch")"
original="$(cat "$(tf_gh_file "$endpoint")")"
# A second page with older active CI must prevent deletion.
tf_gh_put "$endpoint" "$original"$'\n''{"workflow_runs":[{"status":"queued"}]}'
t_run catalog --prune --json
assert_rc 0 'paginated evidence read'
assert_eq false "$(jq -r --arg b "$test_branch" '.items[]|select(.branch==$b)|.safe_to_delete' <<< "$T_OUT")" 'active job on another page blocks pruning'
tf_gh_put "$endpoint" "$original"
tf_gh_put "repos/acme/candidates/rules/branches/$(jq -rn --arg b "$test_branch" '$b|@uri')" '[{"type":"deletion"}]'
t_run catalog --json
assert_eq deletion_protected "$(jq -r --arg b "$test_branch" '.items[]|select(.branch==$b)|.reason' <<< "$T_OUT")" 'deletion protection respected'
tf_gh_put "repos/acme/candidates/rules/branches/$(jq -rn --arg b "$test_branch" '$b|@uri')" '[]'
MOCK_CANDIDATE_LEGACY=true t_run catalog --json
assert_eq legacy_protection "$(jq -r --arg b "$test_branch" '.items[]|select(.branch==$b)|.reason' <<< "$T_OUT")" 'legacy protection respected'

t_case 'Apply rechecks CI, validates the destination and uses exact ref leases'
before="$(tf_remote_refs "$TF_TMP/candidates.git")"
MOCK_CANDIDATE_BAD_PUSH=true t_run catalog --prune --apply
assert_rc 1 'multiple push destinations refused'
assert_eq "$before" "$(tf_remote_refs "$TF_TMP/candidates.git")" 'bad destination changes nothing'
# Only expose the test candidate so the second read is its immediate recheck.
"$RF_REAL_GIT" --git-dir="$TF_TMP/candidates.git" update-ref -d "refs/heads/$prod_branch" "$prod_commit"
MOCK_CANDIDATE_CI_RACE="$TF_TMP/ci-race" t_run catalog --prune --apply
assert_rc 5 'new CI after planning refuses apply'
assert_contains "$(tf_remote_refs "$TF_TMP/candidates.git")" "$test_commit" 'CI race preserves the branch'
new_commit="$(printf 'Concurrent change\n' | "$RF_REAL_GIT" -C "$repo" -c user.name=Tester -c user.email=tester@example.com commit-tree "$test_commit^{tree}" -p "$test_commit")"
"$RF_REAL_GIT" -C "$repo" push origin "$new_commit:refs/heads/race-source" >/dev/null 2>&1
printf 'refs/heads/%s %s\n' "$test_branch" "$new_commit" > "$TF_TMP/ref-race"
MOCK_CANDIDATE_REF_RACE="$TF_TMP/ref-race" t_run catalog --prune --apply
assert_rc 5 'concurrent branch movement rejects the atomic deletion'
assert_contains "$(tf_remote_refs "$TF_TMP/candidates.git")" "$new_commit" 'new commit survives'
"$RF_REAL_GIT" --git-dir="$TF_TMP/candidates.git" update-ref "refs/heads/$test_branch" "$test_commit" "$new_commit"
t_run catalog --prune --apply --json
assert_rc 0 'explicit apply deletes the completed test candidate'
assert_eq '' "$(git -C "$repo" ls-remote origin "refs/heads/$test_branch")" 'eligible branch was removed'
assert_contains "$(tf_remote_refs "$TF_TMP/candidates.git")" 'refs/heads/develop' 'integration branch preserved'
"$RF_REAL_GIT" --git-dir="$TF_TMP/candidates.git" update-ref "refs/heads/$prod_branch" "$prod_commit"

t_case 'Unknown CI fails closed'
tf_gh_rm "$(runs_endpoint "$prod_branch")"
t_run catalog --prune --apply
assert_rc 1 'API failure refuses pruning'
assert_contains "$(tf_remote_refs "$TF_TMP/candidates.git")" "$prod_commit" 'production candidate remains'
t_case 'Published production evidence and historical required channels'
tf_candidate_ci "$repo" "$prod_branch" "$prod_commit"
record_run
t_run bash "$ROOT/scripts/release-promote.sh" --project-dir "$repo" --candidate "$prod_branch" --commit "$prod_commit"
assert_rc 0 'production fixture uses guarded signed promotion'
tf_mock_tools_on
t_run bash "$ROOT/scripts/release-retry.sh" --project-dir "$repo" "$TF_V" github-release --local
assert_rc 0 'fixture publishes GitHub assets'
t_run catalog --json
assert_eq false "$(jq -r '.items[0].safe_to_delete' <<< "$T_OUT")" 'partial publication kept'
cp "$repo/.release-flow.json" "$TF_TMP/current-config"
jq 'del(.publishers.oci)' "$TF_TMP/current-config" > "$repo/.release-flow.json"
t_run catalog --json
assert_rc 0 'historical config loaded'
assert_eq false "$(jq -r '.items[0].safe_to_delete' <<< "$T_OUT")" 'current config cannot waive historical required OCI'
cp "$TF_TMP/current-config" "$repo/.release-flow.json"
t_run bash "$ROOT/scripts/release-retry.sh" --project-dir "$repo" "$TF_V" oci --local
assert_rc 0 'fixture publishes remaining required channel'
t_run catalog --prune --dry-run --json
assert_rc 0 'published catalog succeeds'
assert_eq true "$(jq -r '.items[0].safe_to_delete' <<< "$T_OUT")" 'fully published exact source is eligible'
assert_eq fully_published "$(jq -r '.items[0].reason' <<< "$T_OUT")" 'eligibility explains publication'
assert_eq stale "$(jq -r '.items[0].base_status' <<< "$T_OUT")" 'promotion makes recorded base stale'
assert_contains "$(tf_remote_refs "$TF_TMP/candidates.git")" 'refs/tags/0.1.1' 'dry run preserves signed version tag'
t_finish
