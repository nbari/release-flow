#!/usr/bin/env bash
# Test the branch-aware `just deploy` module (.justfiles/deploy.just) and its
# orchestrator (scripts/release-deploy.sh). No Cargo/Rust toolchain may run.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

orig_dir="$(pwd)"
tf_forbid_toolchains

EXPECTED_KEYS="project version mode base_branch base_commit candidate_branch candidate_commit pushed remote ci_url"

# out_kv <key>: value of a key=value line in T_OUT.
out_kv() {
  printf '%s\n' "${T_OUT}" | sed -n "s/^$1=//p"
}

out_keys() {
  printf '%s\n' "${T_OUT}" | sed 's/=.*//' | tr '\n' ' ' | sed 's/ $//'
}

local_release_count() {
  git for-each-ref refs/heads/release | wc -l | tr -d ' '
}

remote_release_heads() {
  git ls-remote --heads origin | grep 'refs/heads/release/' || true
}

trailer() {
  git log -1 --format="%(trailers:key=$1,valueonly)" "$2" | tr -d ' \n'
}

lock_state() {
  if [[ -e "$(git rev-parse --path-format=absolute --git-common-dir)/release-flow/worktrees/.prepare.lock" ]]; then
    echo present
  else
    echo absent
  fi
}

base_refs() {
  git for-each-ref --format='%(refname) %(objectname)' refs/heads/main refs/heads/develop refs/heads/sandbox
  git ls-remote --heads origin main develop sandbox
}

# assert_candidate <mode> <version> <base-branch> <label>
assert_candidate() {
  local mode="$1" version="$2" base="$3" label="$4" base_sha base12 branch local_sha remote_sha
  base_sha="$(git rev-parse "refs/heads/${base}")"
  base12="${base_sha:0:12}"
  if [[ "${mode}" == "test-only" ]]; then
    branch="release/test/${version}-${base12}"
  else
    branch="release/${version}-${base12}"
  fi
  assert_eq "${EXPECTED_KEYS}" "$(out_keys)" "${label}: stdout keys in contract order"
  assert_eq "${version}" "$(out_kv version)" "${label}: version"
  assert_eq "${mode}" "$(out_kv mode)" "${label}: mode"
  assert_eq "${base}" "$(out_kv base_branch)" "${label}: base branch"
  assert_eq "${base_sha}" "$(out_kv base_commit)" "${label}: base commit is HEAD"
  assert_eq "${branch}" "$(out_kv candidate_branch)" "${label}: candidate branch name"
  assert_eq "true" "$(out_kv pushed)" "${label}: pushed"
  assert_eq "origin" "$(out_kv remote)" "${label}: remote"
  local_sha="$(git rev-parse --verify --quiet "refs/heads/${branch}" || true)"
  remote_sha="$(git ls-remote origin "refs/heads/${branch}" | awk '{print $1}')"
  assert_eq "$(out_kv candidate_commit)" "${local_sha}" "${label}: local candidate branch"
  assert_eq "${local_sha}" "${remote_sha}" "${label}: remote candidate branch matches local"
  if [[ -n "${local_sha}" ]]; then
    assert_eq "${mode}" "$(trailer Release-Mode "${local_sha}")" "${label}: Release-Mode trailer"
    assert_eq "${base}" "$(trailer Release-Base-Branch "${local_sha}")" "${label}: Release-Base-Branch trailer"
    assert_eq "${version}" "$(trailer Release-Version "${local_sha}")" "${label}: Release-Version trailer"
    assert_eq "${base_sha}" "$(git rev-parse "${local_sha}^1")" "${label}: candidate parent is base HEAD"
  fi
  if [[ "${mode}" == "test-only" ]]; then
    assert_contains "${T_ERR}" "Deployed test-only candidate ${version}" "${label}: summary names test-only"
    assert_contains "${T_ERR}" "Test-only candidates are never promotable to production." "${label}: test-only warning"
  else
    assert_contains "${T_ERR}" "Deployed production candidate ${version}" "${label}: summary names production"
    assert_contains "${T_ERR}" "Promotion is a separate, explicitly authorized step." "${label}: promotion note"
  fi
}

# assert_rejected_unchanged <rc> <stderr-needle> <label> -- runs `just deploy` in $PWD
assert_rejected_unchanged() {
  local rc="$1" needle="$2" label="$3" repo before
  repo="$(git rev-parse --show-toplevel)"
  before="$(tf_snapshot "${repo}")"
  t_run just deploy
  assert_rc "${rc}" "${label}: exit ${rc}"
  assert_contains "${T_ERR}" "${needle}" "${label}: explains rejection"
  assert_eq "" "${T_OUT}" "${label}: stdout empty"
  assert_eq "${before}" "$(tf_snapshot "${repo}")" "${label}: no Git changes"
}

# ---------------------------------------------------------------------------

t_case "D01: Interface (top-level recipes, no module namespace, root default kept)"
repo="$(tf_fixture_repo "deploy-interface" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
t_run just --list
assert_rc 0 "D01: just --list succeeds"
assert_contains "${T_OUT}" "deploy " "D01: lists deploy"
assert_contains "${T_OUT}" "deploy-minor" "D01: lists deploy-minor"
assert_contains "${T_OUT}" "deploy-major" "D01: lists deploy-major"
assert_not_contains "${T_OUT}" "deploy::" "D01: no deploy:: namespace"
t_run just --summary
assert_contains " ${T_OUT} " " deploy " "D01: deploy is a top-level recipe"
assert_contains " ${T_OUT} " " deploy-minor " "D01: deploy-minor is a top-level recipe"
assert_contains " ${T_OUT} " " deploy-major " "D01: deploy-major is a top-level recipe"
t_run just deploy::deploy
assert_rc nonzero "D01: just deploy::deploy does not exist"
t_run just
assert_rc 0 "D01: plain just runs the root default"
assert_eq "root-default" "${T_OUT}" "D01: root default recipe unchanged by import"
cd "${orig_dir}"

t_case "D02: Downstream repository installed from the bundle, without Cargo"
bundle_out="${TF_TMP}/bundle-out"
bundle_archive="$(bash "${ROOT}/scripts/release-flow-bundle.sh" --version 9.9.9 --out "${bundle_out}" 2>/dev/null)"
tar -xzf "${bundle_archive}" -C "${bundle_out}"
BUNDLE_ROOT="${bundle_out}/release-flow-bundle-9.9.9"
tf_install_bundle() {
  bash "${BUNDLE_ROOT}/install.sh" --target . >/dev/null 2>&1
  printf "import '.justfiles/deploy.just'\n\ndefault:\n    @echo root-default\n" > .justfile
}
repo="$(tf_fixture_repo "deploy-bundle" 0.1.0 tf_install_bundle)"
cd "${repo}"
assert_eq "present" "$(test -f .release-flow-bundle.json && echo present || echo absent)" "D02: bundle lock committed"
t_run just deploy
assert_rc 0 "D02: just deploy succeeds in a bundle-installed repo"
assert_eq "test-only" "$(out_kv mode)" "D02: sandbox gives test-only"
assert_eq "absent" "$(test -e "${TF_TMP}/forbidden-tools.log" && echo present || echo absent)" "D02: no Cargo/Rust tool invoked"
cd "${orig_dir}"

t_case "D03: Importing justfile settings do not break deploy"
tf_vendor_deploy_settings() {
  tf_vendor_deploy
  mkdir -p sub
  printf 'keep\n' > sub/.keep
  cat <<'EOF' > .justfile
set shell := ["bash", "-euc"]
set positional-arguments
set export
set working-directory := 'sub'

import '.justfiles/deploy.just'

default:
    @echo root-default
EOF
}
repo="$(tf_fixture_repo "deploy-settings" 0.1.0 tf_vendor_deploy_settings)"
cd "${repo}"
t_run just deploy
assert_rc 0 "D03: deploy succeeds with shell/positional/export/working-directory settings"
assert_candidate test-only 0.1.1 sandbox "D03"
cd "${orig_dir}"

t_case "D04: sandbox + deploy -> test-only patch candidate"
repo="$(tf_fixture_repo "deploy-sandbox-patch" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
before_bases="$(base_refs)"
t_run just deploy
assert_rc 0 "D04: deploy succeeds"
assert_candidate test-only 0.1.1 sandbox "D04"
assert_eq "${before_bases}" "$(base_refs)" "D04: main/develop/sandbox unchanged locally and remotely"
assert_eq "sandbox" "$(git symbolic-ref --short HEAD)" "D04: HEAD still on sandbox"
assert_eq "1" "$(git worktree list --porcelain | grep -c '^worktree ')" "D04: no extra worktree"
assert_eq "absent" "$(lock_state)" "D04: lock released"
assert_eq "" "$(out_kv ci_url)" "D04: ci_url empty for non-GitHub remote"
assert_contains "${T_OUT}" $'\nci_url=' "D04: ci_url key present"
cd "${orig_dir}"

t_case "D05: sandbox + deploy-minor -> test-only minor candidate"
repo="$(tf_fixture_repo "deploy-sandbox-minor" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
t_run just deploy-minor
assert_rc 0 "D05: deploy-minor succeeds"
assert_candidate test-only 0.2.0 sandbox "D05"
cd "${orig_dir}"

t_case "D06: sandbox + deploy-major -> test-only major candidate"
repo="$(tf_fixture_repo "deploy-sandbox-major" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
t_run just deploy-major
assert_rc 0 "D06: deploy-major succeeds"
assert_candidate test-only 1.0.0 sandbox "D06"
cd "${orig_dir}"

t_case "D07: develop + deploy -> production candidate with GitHub CI URL"
repo="$(tf_fixture_repo "deploy-develop-patch" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout develop --quiet
git config remote.origin.url "https://github.com/acme/demo.git"
git config "url.${TF_TMP}/deploy-develop-patch.git.insteadOf" "https://github.com/acme/demo.git"
before_main="$(git rev-parse refs/heads/main) $(git ls-remote origin refs/heads/main | awk '{print $1}')"
t_run just deploy
assert_rc 0 "D07: deploy succeeds"
assert_candidate production 0.1.1 develop "D07"
assert_eq "${before_main}" "$(git rev-parse refs/heads/main) $(git ls-remote origin refs/heads/main | awk '{print $1}')" "D07: main unchanged"
cand_branch="$(out_kv candidate_branch)"
assert_eq "https://github.com/acme/demo/actions?query=branch%3A${cand_branch//\//%2F}" "$(out_kv ci_url)" "D07: ci_url derived from GitHub remote"
assert_contains "${T_ERR}" "https://github.com/acme/demo/actions" "D07: summary shows CI URL"
cd "${orig_dir}"

t_case "D08: develop + deploy-minor / deploy-major -> production candidates"
repo="$(tf_fixture_repo "deploy-develop-minor" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout develop --quiet
t_run just deploy-minor
assert_rc 0 "D08: deploy-minor succeeds"
assert_candidate production 0.2.0 develop "D08 minor"
cd "${orig_dir}"
repo="$(tf_fixture_repo "deploy-develop-major" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout develop --quiet
t_run just deploy-major
assert_rc 0 "D08: deploy-major succeeds"
assert_candidate production 1.0.0 develop "D08 major"
cd "${orig_dir}"

t_case "D09: Branch policy comes from .release-flow.json"
tf_vendor_deploy_custom_bases() {
  tf_vendor_deploy
  cat <<'EOF' > .release-flow.json
{
  "schema_version": 1,
  "project": "deploy-custom-bases",
  "adapter": "tools/adapter.sh",
  "remote": "origin",
  "production_base": "trunk",
  "test_base": "playground"
}
EOF
}
repo="$(tf_fixture_repo "deploy-custom-bases" 0.1.0 tf_vendor_deploy_custom_bases)"
cd "${repo}"
git checkout -b trunk main --quiet
git push -u origin trunk --quiet
git checkout -b playground main --quiet
git commit --allow-empty -m "Playground commit" --quiet
git push -u origin playground --quiet
t_run just deploy
assert_rc 0 "D09: playground deploy succeeds"
assert_candidate test-only 0.1.1 playground "D09 playground"
git checkout trunk --quiet
t_run just deploy
assert_rc 0 "D09: trunk deploy succeeds"
assert_candidate production 0.1.1 trunk "D09 trunk"
git checkout sandbox --quiet
assert_rejected_unchanged 3 "Allowed: 'playground' (test-only candidate), 'trunk' (production candidate)." "D09 sandbox"
cd "${orig_dir}"

t_case "D10: main is rejected without Git changes"
repo="$(tf_fixture_repo "deploy-main" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout main --quiet
assert_rejected_unchanged 3 "Refusing to deploy from 'main': main receives only guarded release promotion" "D10"
cd "${orig_dir}"

t_case "D11: Detached HEAD is rejected without Git changes"
repo="$(tf_fixture_repo "deploy-detached" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout --detach sandbox --quiet
assert_rejected_unchanged 3 "detached HEAD" "D11"
cd "${orig_dir}"

t_case "D12: Unsupported branch is rejected without Git changes"
repo="$(tf_fixture_repo "deploy-feature" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout -b feature/x --quiet
assert_rejected_unchanged 3 "Allowed: 'sandbox' (test-only candidate), 'develop' (production candidate)." "D12"
cd "${orig_dir}"

t_case "D13: Checked-out candidate branch is rejected without Git changes"
repo="$(tf_fixture_repo "deploy-candidate-branch" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git checkout -b release/test/0.0.1-000000000000 --quiet
assert_rejected_unchanged 3 "is a release candidate branch" "D13"
cd "${orig_dir}"

t_case "D14: Configuration errors are rejected without Git changes"
repo="$(tf_fixture_repo "deploy-config" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
write_config() {
  printf '{"schema_version": %s, "project": "deploy-config", "adapter": "tools/adapter.sh", "remote": "origin", "production_base": "%s", "test_base": "%s"}\n' "$1" "$2" "$3" > .release-flow.json
  git commit -qam "config: $*"
}
write_config 2 develop sandbox
assert_rejected_unchanged 1 "Unsupported schema_version" "D14 schema_version 2"
write_config 1 sandbox sandbox
assert_rejected_unchanged 1 "production_base and test_base must differ" "D14 equal bases"
write_config 1 main sandbox
assert_rejected_unchanged 1 "must not be 'main'" "D14 main base"
git rm -q .release-flow.json
git commit -qm "config: removed"
assert_rejected_unchanged 1 "Missing .release-flow.json at HEAD" "D14 missing config"
cd "${orig_dir}"

t_case "D15: Uncommitted changes are rejected before any fetch"
repo="$(tf_fixture_repo "deploy-dirty" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
echo "dirty" >> README.md
assert_rejected_unchanged 1 "Working tree is dirty" "D15 tracked edit"
git checkout -- README.md
echo "untracked" > untracked.txt
assert_rejected_unchanged 1 "Working tree is dirty" "D15 untracked file"
rm -f untracked.txt
cd "${orig_dir}"

t_case "D16: Invalid bump arguments are usage errors"
repo="$(tf_fixture_repo "deploy-usage" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
before="$(tf_snapshot "${repo}")"
for args in "1.2.3" "" "--bogus" "patch minor"; do
  # shellcheck disable=SC2086
  t_run bash scripts/release-deploy.sh ${args}
  assert_rc 2 "D16 '${args}': exit 2"
  assert_contains "${T_ERR}" "Usage: release-deploy.sh" "D16 '${args}': prints usage"
done
assert_eq "${before}" "$(tf_snapshot "${repo}")" "D16: no Git changes"
cd "${orig_dir}"

t_case "D17: Local base ahead of its remote"
repo="$(tf_fixture_repo "deploy-ahead" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
remote_sandbox="$(git ls-remote origin refs/heads/sandbox | awk '{print $1}')"
git commit --allow-empty -m "Unpushed sandbox commit" --quiet
t_run just deploy
assert_rc 1 "D17: rejected"
assert_contains "${T_ERR}" "has unpushed commits" "D17: explains unpushed commits"
assert_eq "" "${T_OUT}" "D17: stdout empty"
assert_eq "0" "$(local_release_count)" "D17: no local candidate"
assert_eq "" "$(remote_release_heads)" "D17: no remote candidate"
assert_eq "${remote_sandbox}" "$(git ls-remote origin refs/heads/sandbox | awk '{print $1}')" "D17: remote sandbox unchanged"
assert_eq "absent" "$(lock_state)" "D17: lock released"
cd "${orig_dir}"

t_case "D18: Local base behind its remote"
repo="$(tf_fixture_repo "deploy-behind" 0.1.0 tf_vendor_deploy)"
other="${TF_TMP}/deploy-behind-other"
git clone --quiet --branch sandbox "${TF_TMP}/deploy-behind.git" "${other}"
(
  cd "${other}"
  git commit --allow-empty -m "Commit from another clone" --quiet
  git push origin sandbox --quiet
)
cd "${repo}"
t_run just deploy
assert_rc 1 "D18: rejected"
assert_contains "${T_ERR}" "Base mismatch" "D18: explains base mismatch"
assert_eq "0" "$(local_release_count)" "D18: no local candidate"
assert_eq "" "$(remote_release_heads)" "D18: no remote candidate"
assert_eq "absent" "$(lock_state)" "D18: lock released"
git pull --ff-only --quiet
t_run just deploy
assert_rc 0 "D18: retry after pull succeeds"
assert_candidate test-only 0.1.1 sandbox "D18 retry"
cd "${orig_dir}"

t_case "D19: Base branch missing on the remote"
repo="$(tf_fixture_repo "deploy-no-remote-base" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git push --quiet origin :sandbox
t_run just deploy
assert_rc 1 "D19: rejected"
assert_contains "${T_ERR}" "Failed to fetch base branch" "D19: explains missing remote base"
assert_eq "0" "$(local_release_count)" "D19: no local candidate"
assert_eq "" "$(remote_release_heads)" "D19: no remote candidate"
assert_eq "absent" "$(lock_state)" "D19: lock released"
cd "${orig_dir}"

t_case "D20: Candidate branch already exists on the remote"
repo="$(tf_fixture_repo "deploy-remote-collision" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
sandbox_sha="$(git rev-parse HEAD)"
collide="release/test/0.1.1-${sandbox_sha:0:12}"
other="${TF_TMP}/deploy-remote-collision-other"
git clone --quiet --branch main "${TF_TMP}/deploy-remote-collision.git" "${other}"
(
  cd "${other}"
  git push --quiet origin "refs/remotes/origin/main:refs/heads/${collide}"
)
remote_before="$(git ls-remote origin "refs/heads/${collide}" | awk '{print $1}')"
t_run just deploy
assert_rc 1 "D20: rejected"
assert_contains "${T_ERR}" "Branch collision" "D20: explains branch collision"
assert_eq "${remote_before}" "$(git ls-remote origin "refs/heads/${collide}" | awk '{print $1}')" "D20: remote candidate ref unchanged"
assert_eq "0" "$(local_release_count)" "D20: no local candidate"
cd "${orig_dir}"

t_case "D21: Server rejects the candidate push"
repo="$(tf_fixture_repo "deploy-push-reject" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
cat <<'EOF' > "${TF_TMP}/deploy-push-reject.git/hooks/pre-receive"
#!/usr/bin/env bash
while read -r old new ref; do
  if [[ "${ref}" == refs/heads/release/* ]]; then
    echo "Simulated server rejection of release branch" >&2
    exit 1
  fi
done
EOF
chmod +x "${TF_TMP}/deploy-push-reject.git/hooks/pre-receive"
t_run just deploy
assert_rc nonzero "D21: push rejection fails deploy"
assert_eq "" "${T_OUT}" "D21: stdout empty"
assert_contains "${T_ERR}" "Push failed" "D21: push failure reported"
assert_contains "${T_ERR}" "Retry push manually" "D21: retry command printed"
assert_eq "1" "$(local_release_count)" "D21: local candidate kept for recovery"
assert_eq "" "$(remote_release_heads)" "D21: no remote candidate"
cd "${orig_dir}"

t_case "D22: Remote tag collision"
repo="$(tf_fixture_repo "deploy-tag-collision" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git tag 0.1.1 main
git push --quiet origin refs/tags/0.1.1
git tag -d 0.1.1 >/dev/null
t_run just deploy
assert_rc 1 "D22: rejected"
assert_contains "${T_ERR}" "Tag collision" "D22: explains tag collision"
assert_eq "0" "$(local_release_count)" "D22: no local candidate"
assert_eq "" "$(remote_release_heads)" "D22: no remote candidate"
cd "${orig_dir}"

t_case "D23: Run from a nested directory with decoy scripts and config"
tf_vendor_deploy_nested() {
  tf_vendor_deploy
  mkdir -p pkg/a/b/scripts
  printf '#!/usr/bin/env bash\necho decoy >&2\nexit 99\n' > pkg/a/b/scripts/release-deploy.sh
  chmod +x pkg/a/b/scripts/release-deploy.sh
  printf '{"schema_version": 1, "project": "decoy", "adapter": "nope.sh", "remote": "nowhere", "production_base": "x", "test_base": "y"}\n' > pkg/a/b/.release-flow.json
}
repo="$(tf_fixture_repo "deploy-nested" 0.1.0 tf_vendor_deploy_nested)"
cd "${repo}/pkg/a/b"
t_run just deploy
assert_rc 0 "D23: deploy from nested directory succeeds"
assert_not_contains "${T_ERR}" "decoy" "D23: decoy script not used"
cd "${repo}"
assert_candidate test-only 0.1.1 sandbox "D23"
assert_eq "deploy-nested" "$(out_kv project)" "D23: root configuration used"
cd "${orig_dir}"

t_case "D24: Run from an ignored nested Git repository"
tf_vendor_deploy_ignored_vendor() {
  tf_vendor_deploy
  printf 'vendor/\n' > .gitignore
}
repo="$(tf_fixture_repo "deploy-inner-repo" 0.1.0 tf_vendor_deploy_ignored_vendor)"
inner="${repo}/vendor/inner"
mkdir -p "${inner}"
git -C "${inner}" init --quiet
git -C "${inner}" checkout -b sandbox --quiet
git -C "${inner}" commit --allow-empty -m "Inner commit" --quiet
inner_before="$(git -C "${inner}" for-each-ref --format='%(refname) %(objectname)'; git -C "${inner}" symbolic-ref HEAD; git -C "${inner}" rev-parse HEAD)"
cd "${inner}"
t_run just deploy
assert_rc 0 "D24: deploy from inner repository succeeds"
assert_eq "deploy-inner-repo" "$(out_kv project)" "D24: outer repository deployed"
cd "${repo}"
assert_candidate test-only 0.1.1 sandbox "D24"
assert_eq "${inner_before}" "$(git -C "${inner}" for-each-ref --format='%(refname) %(objectname)'; git -C "${inner}" symbolic-ref HEAD; git -C "${inner}" rev-parse HEAD)" "D24: inner repository unchanged"
cd "${orig_dir}"
t_case "D25: Same-named tag does not interfere with branch detection"
repo="$(tf_fixture_repo "deploy-samename-tag" 0.1.0 tf_vendor_deploy)"
cd "${repo}"
git tag sandbox
t_run just deploy
assert_rc 0 "D25: deploy succeeds when tag matches branch name"
assert_candidate test-only 0.1.1 sandbox "D25"
cd "${orig_dir}"

t_case "No Cargo/Rust toolchain was invoked by any deploy scenario"
assert_eq "absent" "$(test -e "${TF_TMP}/forbidden-tools.log" && echo present || echo absent)" "forbidden-tools.log absent"

t_finish
