#!/usr/bin/env bash
# Guarded atomic promotion (scripts/release-promote.sh): preflight evidence,
# exact-SHA pins, stale and racing candidates, rejected and lost pushes,
# interruption, protection and signing readiness. No toolchain may run.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pipeline/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

tf_forbid_toolchains
tf_mock_gh_on
REAL_GIT="$(command -v git)"
SHIM_DIR="${TF_TMP}/git-shim"
mkdir -p "${SHIM_DIR}"
ln -s "${TF_FIXTURES}/git-fault-shim.sh" "${SHIM_DIR}/git"

EXPECTED_KEYS="project version tag tag_object candidate_branch candidate_commit base_commit run_id run_attempt manifest_sha256 main_before state already_promoted promoted_by_other reconciled"

out_kv() {
  printf '%s\n' "${T_OUT}" | sed -n "s/^$1=//p"
}

out_keys() {
  printf '%s\n' "${T_OUT}" | sed 's/=.*//' | tr '\n' ' ' | sed 's/ $//'
}

promote() {
  local repo="$1"
  shift
  t_run bash "${repo}/scripts/release-promote.sh" --project-dir "${repo}" "$@"
}

pass_count() {
  printf '%s\n' "${T_ERR}" | grep -c '^\[PF[0-9][0-9]\] PASS' || true
}

exists() {
  if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

# state_of <repo> <name>: local snapshot plus the bare remote refs
state_of() {
  tf_snapshot "$1"
  printf '=== BARE ===\n'
  tf_remote_refs "${TF_TMP}/$2.git"
}

# assert_refused <repo> <name> <check> <needle> <label> [promote args...]
assert_refused() {
  local repo="$1" name="$2" check="$3" needle="$4" label="$5" before
  shift 5
  before="$(state_of "${repo}" "${name}")"
  promote "${repo}" "$@"
  assert_rc 3 "${label}: exit 3"
  assert_contains "${T_ERR}" "[${check}] FAIL" "${label}: ${check} fails"
  assert_contains "${T_ERR}" "${needle}" "${label}: explains (${needle})"
  assert_eq "" "${T_OUT}" "${label}: stdout empty"
  assert_eq "${before}" "$(state_of "${repo}" "${name}")" "${label}: local and remote unchanged"
}

lock_path() {
  printf '%s/.git/release-flow/promote.lock' "$1"
}

remote_tag_count() {
  git ls-remote --tags --refs "${TF_TMP}/$1.git" | grep -cE 'refs/tags/v?[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# hold_gate <name> <sha>: a pre-receive hook in the bare remote that holds the
# first push updating any ref to <sha> until ${TF_TMP}/gate-<name>/open exists.
hold_gate() {
  local gate="${TF_TMP}/gate-$1" hook="${TF_TMP}/$1.git/hooks/pre-receive"
  mkdir -p "${gate}"
  printf '%s\n' "$2" > "${gate}/hold"
  cat <<EOF > "${hook}"
#!/usr/bin/env bash
gate="${gate}"
while read -r old new ref; do
  if [[ -f "\${gate}/hold" && "\${new}" == "\$(cat "\${gate}/hold" 2>/dev/null)" ]] && mv "\${gate}/hold" "\${gate}/holding.\$\$" 2>/dev/null; then
    touch "\${gate}/arrived"
    for _ in \$(seq 1 300); do
      [[ -f "\${gate}/open" ]] && break
      sleep 0.1
    done
  fi
done
exit 0
EOF
  chmod +x "${hook}"
}

wait_for() {
  local f="$1" i
  for i in $(seq 1 300); do
    [[ -e "${f}" ]] && return 0
    sleep 0.1
  done
  return 1
}

# promote_bg <repo> <tag>: background promotion; results in ${TF_TMP}/bg-<tag>.{out,err,rc}
promote_bg() {
  local repo="$1" tag="$2"
  shift 2
  (
    rc=0
    bash "${repo}/scripts/release-promote.sh" --project-dir "${repo}" "$@" \
      > "${TF_TMP}/bg-${tag}.out" 2> "${TF_TMP}/bg-${tag}.err" || rc=$?
    echo "${rc}" > "${TF_TMP}/bg-${tag}.rc"
  ) &
  BG_PID=$!
}

# ---------------------------------------------------------------------------

t_case "PR01: Happy path"
repo="$(tf_release_repo pr01)"
tf_candidate "${repo}" patch
sandbox_before="$(git ls-remote "${TF_TMP}/pr01.git" refs/heads/sandbox)"
branch_before="$(git ls-remote "${TF_TMP}/pr01.git" "refs/heads/${TF_BRANCH}")"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR01: promote succeeds"
assert_eq "${EXPECTED_KEYS}" "$(out_keys)" "PR01: stdout keys in contract order"
assert_eq "PROMOTED" "$(out_kv state)" "PR01: state PROMOTED"
assert_eq "0.1.1" "$(out_kv version)" "PR01: version"
assert_eq "${TF_C}" "$(out_kv candidate_commit)" "PR01: candidate commit"
assert_eq "${TF_M}" "$(out_kv manifest_sha256)" "PR01: manifest digest"
assert_eq "false" "$(out_kv already_promoted)" "PR01: not already promoted"
assert_eq "false" "$(out_kv reconciled)" "PR01: not reconciled"
bare="${TF_TMP}/pr01.git"
assert_eq "${TF_C}" "$(git --git-dir="${bare}" rev-parse refs/heads/main)" "PR01: remote main is C"
assert_eq "${TF_C}" "$(git --git-dir="${bare}" rev-parse refs/heads/develop)" "PR01: remote develop is C"
assert_eq "tag" "$(git --git-dir="${bare}" cat-file -t refs/tags/0.1.1)" "PR01: remote tag is annotated"
assert_eq "${TF_C}" "$(git --git-dir="${bare}" rev-parse 'refs/tags/0.1.1^{commit}')" "PR01: tag peels to C"
assert_eq "$(out_kv tag_object)" "$(git --git-dir="${bare}" rev-parse refs/tags/0.1.1)" "PR01: tag_object is the remote tag"
assert_eq "20" "$(pass_count)" "PR01: 20 preflight checks pass"
t_run git -C "${repo}" verify-tag 0.1.1
assert_rc 0 "PR01: git verify-tag passes"
trailers="$(git --git-dir="${bare}" cat-file tag refs/tags/0.1.1 | sed '/^-----BEGIN SSH SIGNATURE-----$/,$d' | git interpret-trailers --parse)"
assert_contains "${trailers}" "Release-Manifest-SHA256: ${TF_M}" "PR01: trailer pins the manifest"
assert_contains "${trailers}" "Release-Candidate-Run: ${TF_RUN}" "PR01: trailer pins the run"
assert_contains "${trailers}" "Release-Candidate-Run-Attempt: 1" "PR01: trailer pins the attempt"
assert_contains "${trailers}" "Release-Base-Commit: ${TF_B}" "PR01: trailer pins the base"
assert_contains "${trailers}" "Release-Candidate-Branch: ${TF_BRANCH}" "PR01: trailer pins the branch"
assert_contains "${trailers}" "Release-Storage: file://$(tf_store pr01)" "PR01: trailer records storage"
assert_eq "11" "$(printf '%s\n' "${trailers}" | grep -c '^Release-')" "PR01: exactly the 11 release trailers"
assert_eq "${sandbox_before}" "$(git ls-remote "${bare}" refs/heads/sandbox)" "PR01: sandbox untouched"
assert_eq "${branch_before}" "$(git ls-remote "${bare}" "refs/heads/${TF_BRANCH}")" "PR01: candidate branch untouched"
assert_eq "" "$(git ls-remote "${bare}" refs/tags/v0.1.1)" "PR01: no v-prefixed tag"
assert_eq "absent" "$(exists "$(lock_path "${repo}")")" "PR01: lock released"
assert_eq "" "$(git -C "${repo}" for-each-ref refs/release-flow/)" "PR01: private fetch refs removed"
assert_eq "absent" "$(exists "${TF_TMP}/forbidden-tools.log")" "PR01: no toolchain invoked"

t_case "PR02: Dry run is read-only"
repo="$(tf_release_repo pr02)"
tf_candidate "${repo}" patch
before="$(state_of "${repo}" pr02)"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
assert_rc 0 "PR02: dry run succeeds"
assert_eq "passed" "$(out_kv preflight)" "PR02: preflight=passed"
assert_eq "${TF_M}" "$(out_kv manifest_sha256)" "PR02: reports the manifest digest"
assert_eq "20" "$(pass_count)" "PR02: 20 preflight checks pass"
assert_eq "${before}" "$(state_of "${repo}" pr02)" "PR02: local and remote unchanged"
assert_eq "" "$(git -C "${repo}" tag -l 0.1.1)" "PR02: no local tag"

t_case "PR03: Bad CI evidence"
repo="$(tf_release_repo pr03)"
tf_candidate "${repo}" patch
e4="repos/acme/pr03/actions/workflows/candidate.yml/runs?head_sha=${TF_C}&event=push&per_page=100"
e5="repos/acme/pr03/actions/runs/${TF_RUN}/attempts/1/jobs?per_page=100"
cp "$(tf_gh_file "${e4}")" "${TF_TMP}/pr03-e4"
cp "$(tf_gh_file "${e5}")" "${TF_TMP}/pr03-e5"
tf_gh_edit "${e4}" '.workflow_runs[0].conclusion = "failure"'
assert_refused "${repo}" pr03 PF13 "completed/failure" "PR03 failed run" --candidate "${TF_BRANCH}" --commit "${TF_C}"
tf_gh_rm "${e4}"
assert_refused "${repo}" pr03 PF13 "no .github/workflows/candidate.yml run" "PR03 no run" --candidate "${TF_BRANCH}" --commit "${TF_C}"
cp "${TF_TMP}/pr03-e4" "$(tf_gh_file "${e4}")"
tf_gh_edit "${e4}" '.workflow_runs[0].path = ".github/workflows/other.yml"'
assert_refused "${repo}" pr03 PF13 "no push run of .github/workflows/candidate.yml" "PR03 other workflow" --candidate "${TF_BRANCH}" --commit "${TF_C}"
cp "${TF_TMP}/pr03-e4" "$(tf_gh_file "${e4}")"
tf_gh_edit "${e5}" '(.jobs[] | select(.name == "Candidate OK") | .conclusion) = "failure"'
assert_refused "${repo}" pr03 PF14 "\"Candidate OK\" concluded failure" "PR03 Candidate OK failed" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR04: Test-only candidate refused"
repo="$(tf_release_repo pr04)"
tf_candidate "${repo}" patch --from sandbox
assert_contains "${TF_BRANCH}" "release/test/" "PR04: fixture is a test-only candidate"
assert_refused "${repo}" pr04 PF05 "never promotable" "PR04" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR05: Exact-SHA pin"
repo="$(tf_release_repo pr05)"
tf_candidate "${repo}" patch
assert_refused "${repo}" pr05 PF06 "candidate branch moved" "PR05 other SHA" --candidate "${TF_BRANCH}" --commit "${TF_B}"
wt="${TF_TMP}/pr05-wt"
git -C "${repo}" worktree add --detach --quiet "${wt}" "${TF_C}"
printf 'late change\n' > "${wt}/LATE"
git -C "${wt}" add LATE
git -C "${wt}" commit --quiet -m "late commit"
git -C "${wt}" push --quiet origin "HEAD:refs/heads/${TF_BRANCH}"
git -C "${repo}" worktree remove --force "${wt}"
assert_refused "${repo}" pr05 PF06 "candidate branch moved" "PR05 branch advanced" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR06: Stale develop"
repo="$(tf_release_repo pr06)"
tf_candidate "${repo}" patch
other="$(tf_clone pr06 pr06-other)"
printf 'new work\n' >> "${other}/README.md"
git -C "${other}" commit --quiet -am "develop moved"
git -C "${other}" push --quiet origin develop
assert_refused "${repo}" pr06 PF11 "stale candidate" "PR06" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR07: Main not fast-forward"
repo="$(tf_release_repo pr07)"
tf_candidate "${repo}" patch
other="$(tf_clone pr07 pr07-other)"
git -C "${other}" checkout --quiet main
printf 'hotfix\n' > "${other}/HOTFIX"
git -C "${other}" add HOTFIX
git -C "${other}" commit --quiet -m "hotfix on main"
git -C "${other}" push --quiet origin main
assert_refused "${repo}" pr07 PF12 "cannot fast-forward" "PR07" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR08: Candidate edits a protected path"
# hand_candidate <repo> <version> <path>: production candidate from develop that
# also edits <path>, pushed and given successful CI evidence.
hand_candidate() {
  local repo="$1" version="$2" path="$3" wt base c branch
  git -C "${repo}" fetch --quiet origin
  base="$(git -C "${repo}" rev-parse origin/develop)"
  wt="${TF_TMP}/hand-${version}-$$-${RANDOM}"
  git -C "${repo}" worktree add --detach --quiet "${wt}" "${base}"
  printf '%s\n' "${version}" > "${wt}/VERSION"
  printf '# weakened\n' >> "${wt}/${path}"
  git -C "${wt}" add -A
  git -C "${wt}" commit --quiet -F - <<EOF
release: $(jq -r .project "${wt}/.release-flow.json") ${version}

Release-Project: $(jq -r .project "${wt}/.release-flow.json")
Release-Version: ${version}
Release-Mode: production
Release-Base-Branch: develop
Release-Base-Commit: ${base}
EOF
  c="$(git -C "${wt}" rev-parse HEAD)"
  branch="release/${version}-${base:0:12}"
  git -C "${wt}" push --quiet origin "${c}:refs/heads/${branch}"
  git -C "${repo}" worktree remove --force "${wt}"
  tf_candidate_ci "${repo}" "${branch}" "${c}"
}
repo="$(tf_release_repo pr08)"
hand_candidate "${repo}" 0.1.1 .github/workflows/candidate.yml
assert_refused "${repo}" pr08 PF09 "protected release path .github/workflows/candidate.yml" "PR08 workflow" --candidate "${TF_BRANCH}" --commit "${TF_C}"
hand_candidate "${repo}" 0.2.0 tools/adapter.sh
assert_refused "${repo}" pr08 PF09 "protected release path tools/adapter.sh" "PR08 adapter" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR09: Manifest identity mismatch"
repo="$(tf_release_repo pr09)"
tf_candidate "${repo}" patch
rec="$(tf_store pr09)/candidates/pr09/${TF_C}/${TF_RUN}-1.json"
cp "${rec}" "${TF_TMP}/pr09-rec"
other_m="$(printf 'another manifest' | sha256sum | awk '{print $1}')"
jq --arg m "${other_m}" '.manifest_sha256 = $m' "${TF_TMP}/pr09-rec" > "${rec}"
assert_refused "${repo}" pr09 PF17 "does not match the GitHub artifact" "PR09 stored record" --candidate "${TF_BRANCH}" --commit "${TF_C}"
cp "${TF_TMP}/pr09-rec" "${rec}"
printf 'tampered\n' >> "${MOCK_GH_ROOT}/artifacts/${TF_RUN}/candidate-${TF_C}-1/stub-0.1.1-any.txt"
assert_refused "${repo}" pr09 PF16 "Checksum mismatch" "PR09 tampered download" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR10: Storage blob missing"
repo="$(tf_release_repo pr10)"
tf_candidate "${repo}" patch
rm -f "$(tf_blob_path pr10 "$(tf_artifact_sha stub-0.1.1-oci.tar)")"
packages_before="$(grep -c '^package$' "${STUB_LOG}" || true)"
assert_refused "${repo}" pr10 PF18 "unrecoverable source artifact stub-0.1.1-oci.tar" "PR10" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_contains "${T_ERR}" "it will not be rebuilt" "PR10: says it will not be rebuilt"
assert_eq "${packages_before}" "$(grep -c '^package$' "${STUB_LOG}" || true)" "PR10: nothing was packaged"

t_case "PR11: Version tag already on the remote"
repo="$(tf_release_repo pr11)"
tf_candidate "${repo}" patch
git -C "${repo}" tag -a 0.1.1 -m "squatter" origin/develop
git -C "${repo}" push --quiet origin refs/tags/0.1.1
squat="$(git --git-dir="${TF_TMP}/pr11.git" rev-parse refs/tags/0.1.1)"
assert_refused "${repo}" pr11 PF10 "tag 0.1.1 already exists" "PR11" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_eq "${squat}" "$(git --git-dir="${TF_TMP}/pr11.git" rev-parse refs/tags/0.1.1)" "PR11: remote tag object unchanged"

t_case "PR12: Server rejects one ref"
repo="$(tf_release_repo pr12)"
tf_candidate "${repo}" patch
hook="${TF_TMP}/pr12.git/hooks/update"
printf '#!/bin/sh\nif [ "$1" = refs/heads/develop ]; then echo "develop is protected" >&2; exit 1; fi\nexit 0\n' > "${hook}"
chmod +x "${hook}"
remote_before="$(tf_remote_refs "${TF_TMP}/pr12.git")"
RELEASE_FLOW_RECONCILE_DELAY=0 promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 10 "PR12: rejected push exits 10"
assert_contains "${T_ERR}" "NOT_PROMOTED" "PR12: verdict NOT_PROMOTED"
assert_eq "${remote_before}" "$(tf_remote_refs "${TF_TMP}/pr12.git")" "PR12: remote refs unchanged"
t1="$(git -C "${repo}" rev-parse -q --verify refs/tags/0.1.1 || true)"
assert_eq "tag" "$(git -C "${repo}" cat-file -t "${t1:-none}" 2>/dev/null || echo none)" "PR12: signed local tag kept"
assert_eq "absent" "$(exists "$(lock_path "${repo}")")" "PR12: lock released"
rm -f "${hook}"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR12: rerun succeeds"
assert_contains "${T_ERR}" "(reused)" "PR12: rerun reuses the local tag"
assert_eq "${t1}" "$(git --git-dir="${TF_TMP}/pr12.git" rev-parse refs/tags/0.1.1)" "PR12: remote tag is the original local tag"
assert_eq "false" "$(out_kv reconciled)" "PR12: rerun not reconciled"

t_case "PR13: Response lost after a successful push"
repo="$(tf_release_repo pr13)"
tf_candidate "${repo}" patch
GIT_FAULT=push-lost-response RF_REAL_GIT="${REAL_GIT}" PATH="${SHIM_DIR}:${PATH}" RELEASE_FLOW_RECONCILE_DELAY=0 \
  promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR13: lost response still reports success"
assert_eq "true" "$(out_kv reconciled)" "PR13: reconciled=true"
assert_eq "PROMOTED" "$(out_kv state)" "PR13: PROMOTED"
assert_contains "${T_ERR}" "hung up unexpectedly" "PR13: push error surfaced"
t13="$(git --git-dir="${TF_TMP}/pr13.git" rev-parse refs/tags/0.1.1)"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR13: rerun succeeds"
assert_eq "true" "$(out_kv already_promoted)" "PR13: rerun reports already_promoted"
assert_eq "${t13}" "$(out_kv tag_object)" "PR13: same tag object"
assert_eq "${t13}" "$(git --git-dir="${TF_TMP}/pr13.git" rev-parse refs/tags/0.1.1)" "PR13: remote tag unchanged"
assert_eq "1" "$(remote_tag_count pr13)" "PR13: exactly one remote version tag"

t_case "PR14: Interrupted after local tag creation"
repo="$(tf_release_repo pr14)"
tf_candidate "${repo}" patch
remote_before="$(tf_remote_refs "${TF_TMP}/pr14.git")"
GIT_FAULT=kill-after-tag GIT_FAULT_SIGNAL=TERM RF_REAL_GIT="${REAL_GIT}" PATH="${SHIM_DIR}:${PATH}" \
  t_run_group bash "${repo}/scripts/release-promote.sh" --project-dir "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc nonzero "PR14 TERM: interrupted promotion fails"
assert_eq "${remote_before}" "$(tf_remote_refs "${TF_TMP}/pr14.git")" "PR14 TERM: remote unchanged"
t14="$(git -C "${repo}" rev-parse -q --verify refs/tags/0.1.1 || true)"
assert_eq "tag" "$(git -C "${repo}" cat-file -t "${t14:-none}" 2>/dev/null || echo none)" "PR14 TERM: local tag exists"
assert_eq "absent" "$(exists "$(lock_path "${repo}")")" "PR14 TERM: lock released by the trap"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR14 TERM: rerun succeeds"
assert_eq "${t14}" "$(git --git-dir="${TF_TMP}/pr14.git" rev-parse refs/tags/0.1.1)" "PR14 TERM: remote tag is the interrupted run's tag"

repo="$(tf_release_repo pr14k)"
tf_candidate "${repo}" patch
GIT_FAULT=kill-after-tag GIT_FAULT_SIGNAL=KILL RF_REAL_GIT="${REAL_GIT}" PATH="${SHIM_DIR}:${PATH}" \
  t_run_group bash "${repo}/scripts/release-promote.sh" --project-dir "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc nonzero "PR14 KILL: killed promotion fails"
assert_eq "present" "$(exists "$(lock_path "${repo}")")" "PR14 KILL: lock left behind"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR14 KILL: rerun succeeds"
assert_contains "${T_ERR}" "reclaimed stale promotion lock" "PR14 KILL: stale lock reclaimed"
assert_eq "$(git -C "${repo}" rev-parse refs/tags/0.1.1)" "$(git --git-dir="${TF_TMP}/pr14k.git" rev-parse refs/tags/0.1.1)" "PR14 KILL: remote tag is the local tag"

t_case "PR15: Two candidates race"
repo="$(tf_release_repo pr15)"
tf_candidate "${repo}" patch
a_branch="${TF_BRANCH}"; a_c="${TF_C}"
tf_candidate "${repo}" minor
b_branch="${TF_BRANCH}"; b_c="${TF_C}"
assert_eq "$(git -C "${repo}" rev-parse "${a_c}^")" "$(git -C "${repo}" rev-parse "${b_c}^")" "PR15: both candidates share the base"
hold_gate pr15 "${a_c}"
promote_bg "${repo}" a15 --candidate "${a_branch}" --commit "${a_c}"
a_pid="${BG_PID}"
wait_for "${TF_TMP}/gate-pr15/arrived" || true
assert_eq "present" "$(exists "${TF_TMP}/gate-pr15/arrived")" "PR15: A's push is held at the server"
b_repo="$(tf_clone pr15 pr15-b)"
promote "${b_repo}" --candidate "${b_branch}" --commit "${b_c}"
assert_rc 0 "PR15: B promotes while A is in flight"
touch "${TF_TMP}/gate-pr15/open"
wait "${a_pid}" || true
assert_eq "3" "$(cat "${TF_TMP}/bg-a15.rc")" "PR15: A is refused as stale after its push is rejected"
assert_contains "$(cat "${TF_TMP}/bg-a15.err")" "STALE" "PR15: A reports STALE"
assert_eq "0.2.0" "$(git ls-remote --tags --refs "${TF_TMP}/pr15.git" | sed 's|.*refs/tags/||' | tr '\n' ' ' | sed 's/ $//')" "PR15: remote tags are exactly {0.2.0}"
assert_eq "${b_c}" "$(git --git-dir="${TF_TMP}/pr15.git" rev-parse refs/heads/main)" "PR15: main is C_B"
assert_eq "${b_c}" "$(git --git-dir="${TF_TMP}/pr15.git" rev-parse refs/heads/develop)" "PR15: develop is C_B"
rm -f "${TF_TMP}/pr15.git/hooks/pre-receive"
promote "${repo}" --candidate "${a_branch}" --commit "${a_c}"
assert_rc 3 "PR15: rerun of A is refused"
assert_contains "${T_ERR}" "[PF1" "PR15: rerun of A fails preflight"

t_case "PR16: Same candidate promoted twice at once"
repo="$(tf_release_repo pr16)"
tf_candidate "${repo}" patch
hold_gate pr16 "${TF_C}"
promote_bg "${repo}" a16 --candidate "${TF_BRANCH}" --commit "${TF_C}"
a_pid="${BG_PID}"
wait_for "${TF_TMP}/gate-pr16/arrived" || true
b_repo="$(tf_clone pr16 pr16-b other)"
GIT_COMMITTER_EMAIL=other@example.com promote "${b_repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR16: B promotes"
b_tag="$(out_kv tag_object)"
touch "${TF_TMP}/gate-pr16/open"
wait "${a_pid}" || true
assert_eq "0" "$(cat "${TF_TMP}/bg-a16.rc")" "PR16: A exits 0"
assert_contains "$(cat "${TF_TMP}/bg-a16.out")" "promoted_by_other=true" "PR16: A reports promoted_by_other"
assert_contains "$(cat "${TF_TMP}/bg-a16.err")" "git tag -d 0.1.1" "PR16: A prints the local tag hint"
assert_eq "${b_tag}" "$(git --git-dir="${TF_TMP}/pr16.git" rev-parse refs/tags/0.1.1)" "PR16: the remote tag is B's"
assert_eq "${b_tag}" "$(sed -n 's/^tag_object=//p' "${TF_TMP}/bg-a16.out")" "PR16: A reports B's tag object"
assert_eq "1" "$(remote_tag_count pr16)" "PR16: exactly one remote tag"

t_case "PR17: Protection missing"
repo="$(tf_release_repo pr17)"
tf_candidate "${repo}" patch
tf_gh_put "repos/acme/pr17/rules/branches/main" '[{"type":"deletion"},{"type":"non_fast_forward"}]'
assert_refused "${repo}" pr17 PF20 "required \"Candidate OK\" status check" "PR17 main check" --candidate "${TF_BRANCH}" --commit "${TF_C}"
tf_mock_protection_ok acme/pr17
tf_gh_edit "repos/acme/pr17/rulesets/7" '.rules = [{"type":"creation"}]'
assert_refused "${repo}" pr17 PF20 "no active tag ruleset" "PR17 tag ruleset" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR18: Signing not ready"
repo="$(tf_release_repo pr18)"
tf_candidate "${repo}" patch
git -C "${repo}" config --unset user.signingkey
assert_refused "${repo}" pr18 PF19 "user.signingkey is not set" "PR18 no key" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_eq "" "$(git -C "${repo}" tag -l 0.1.1)" "PR18 no key: no local tag"
git -C "${repo}" config user.signingkey "$(tf_signing_key stranger)"
assert_refused "${repo}" pr18 PF19 "is not in .github/release-flow/allowed_signers" "PR18 unknown key" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_eq "" "$(git -C "${repo}" tag -l 0.1.1)" "PR18 unknown key: no local tag"

# craft_candidate <repo> <version> <message> [extra-parent]: pushes
# release/<version>-<base12>, a commit on origin/develop that sets VERSION,
# with <message> (@BASE@ becomes the base commit) and optionally a second
# parent; no CI evidence (its checks come before PF13). Sets TF_BRANCH TF_C.
craft_candidate() {
  local repo="$1" version="$2" message="$3" extra="${4:-}" base wt tree parents
  git -C "${repo}" fetch --quiet origin
  base="$(git -C "${repo}" rev-parse origin/develop)"
  wt="${TF_TMP}/craft-${version}-$$-${RANDOM}"
  git -C "${repo}" worktree add --detach --quiet "${wt}" "${base}"
  printf '%s\n' "${version}" > "${wt}/VERSION"
  git -C "${wt}" add VERSION
  tree="$(git -C "${wt}" write-tree)"
  parents=(-p "${base}")
  [[ -z "${extra}" ]] || parents+=(-p "${extra}")
  TF_C="$(printf '%s\n' "${message}" | sed "s/@BASE@/${base}/g" | git -C "${wt}" commit-tree "${tree}" "${parents[@]}")"
  TF_BRANCH="release/${version}-${base:0:12}"
  git -C "${wt}" push --quiet origin "${TF_C}:refs/heads/${TF_BRANCH}"
  git -C "${repo}" worktree remove --force "${wt}"
}

t_case "PR19: Corrupted candidate trailers (PF07)"
repo="$(tf_release_repo pr19)"
craft_candidate "${repo}" 0.1.1 "release: pr19 0.1.1

Release-Project: pr19
Release-Version: 0.1.1
Release-Version: 0.1.2
Release-Mode: production
Release-Base-Branch: develop
Release-Base-Commit: @BASE@"
assert_refused "${repo}" pr19 PF07 "trailer Release-Version is '0.1.1,0.1.2'" "PR19 duplicated trailer" --candidate "${TF_BRANCH}" --commit "${TF_C}"
craft_candidate "${repo}" 0.1.2 "release: pr19 0.1.2

Release-Project: pr19
Release-Version: 0.1.2
Release-Mode: test-only
Release-Base-Branch: develop
Release-Base-Commit: @BASE@"
assert_refused "${repo}" pr19 PF07 "trailer Release-Mode is 'test-only', expected 'production'" "PR19 wrong mode" --candidate "${TF_BRANCH}" --commit "${TF_C}"
craft_candidate "${repo}" 0.1.3 "release: pr19 0.1.3

Release-Project: pr19
Release-Version: 0.1.3
Release-Mode: production
Release-Base-Branch: develop
Release-Base-Commit: 0000000000000000000000000000000000000000"
assert_refused "${repo}" pr19 PF07 "does not start with the branch base" "PR19 foreign base" --candidate "${TF_BRANCH}" --commit "${TF_C}"
craft_candidate "${repo}" 0.1.4 "release: pr19 0.1.4

Release-Project: pr19
Release-Version: 0.1.4
Release-Mode: production
Release-Base-Branch: develop
Release-Base-Commit: not-a-commit"
assert_refused "${repo}" pr19 PF07 "Release-Base-Commit is not a 40-character hex commit id" "PR19 malformed base" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR20: Merge commit as candidate (PF08)"
repo="$(tf_release_repo pr20)"
git -C "${repo}" fetch --quiet origin
side="$(git -C "${repo}" commit-tree "$(git -C "${repo}" rev-parse 'origin/develop^{tree}')" -p origin/develop -m "side work")"
craft_candidate "${repo}" 0.1.1 "release: pr20 0.1.1

Release-Project: pr20
Release-Version: 0.1.1
Release-Mode: production
Release-Base-Branch: develop
Release-Base-Commit: @BASE@" "${side}"
assert_eq "3" "$(git -C "${repo}" rev-list --parents -n 1 "${TF_C}" | wc -w | tr -d ' ')" "PR20: fixture is a merge commit"
assert_refused "${repo}" pr20 PF08 "exactly one parent" "PR20" --candidate "${TF_BRANCH}" --commit "${TF_C}"

t_case "PR21: Candidate artifact expired or missing (PF15)"
repo="$(tf_release_repo pr21)"
tf_candidate "${repo}" patch
e15="repos/acme/pr21/actions/runs/${TF_RUN}/artifacts?per_page=100"
cp "$(tf_gh_file "${e15}")" "${TF_TMP}/pr21-e15"
tf_gh_edit "${e15}" '.artifacts[0].expired = true'
assert_refused "${repo}" pr21 PF15 "candidate artifacts expired or missing" "PR21 expired" --candidate "${TF_BRANCH}" --commit "${TF_C}"
tf_gh_put "${e15}" '{"total_count":0,"artifacts":[]}'
assert_refused "${repo}" pr21 PF15 "candidate artifacts expired or missing" "PR21 missing" --candidate "${TF_BRANCH}" --commit "${TF_C}"
tf_gh_rm "${e15}"
assert_refused "${repo}" pr21 PF15 "cannot list artifacts of run ${TF_RUN}" "PR21 listing fails" --candidate "${TF_BRANCH}" --commit "${TF_C}"
cp "${TF_TMP}/pr21-e15" "$(tf_gh_file "${e15}")"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
assert_rc 0 "PR21: restored evidence passes preflight"

t_case "PR22: Push outcome unknown, remote unreachable (exit 11)"
repo="$(tf_release_repo pr22)"
tf_candidate "${repo}" patch
state22="${TF_TMP}/pr22-fault"
mkdir -p "${state22}"
GIT_FAULT=push-lost-unreachable GIT_FAULT_STATE="${state22}" RF_REAL_GIT="${REAL_GIT}" PATH="${SHIM_DIR}:${PATH}" \
  RELEASE_FLOW_RECONCILE_ATTEMPTS=3 RELEASE_FLOW_RECONCILE_DELAY=1 \
  promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 11 "PR22: unknown outcome exits 11"
assert_contains "${T_ERR}" "[T4] UNKNOWN" "PR22: verdict UNKNOWN"
assert_contains "${T_ERR}" "unreachable after 3 attempts" "PR22: names the attempts"
assert_eq "" "${T_OUT}" "PR22: stdout empty"
assert_eq "3" "$(grep -c . "${state22}/git-fault-unreachable.log" || true)" "PR22: exactly 3 reconcile attempts"
gaps="$(awk 'NR > 1 {printf "%s ", ($1 - prev)} {prev = $1}' "${state22}/git-fault-unreachable.log")"
assert_eq "ok" "$(printf '%s\n' "${gaps}" | awk '{print (($1 >= 1 && $2 >= 2) ? "ok" : "gaps " $0)}')" "PR22: retries back off (1 s, then 2 s)"
assert_eq "absent" "$(exists "$(lock_path "${repo}")")" "PR22: lock released"
t22="$(git -C "${repo}" rev-parse refs/tags/0.1.1)"
assert_eq "${t22}" "$(git --git-dir="${TF_TMP}/pr22.git" rev-parse refs/tags/0.1.1)" "PR22: the push had landed"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 0 "PR22: rerun reconciles"
assert_eq "true" "$(out_kv already_promoted)" "PR22: rerun reports already_promoted"
assert_eq "${t22}" "$(out_kv tag_object)" "PR22: rerun reports the pushed tag"
assert_eq "1" "$(remote_tag_count pr22)" "PR22: exactly one remote version tag"

t_case "PR23: Remote tag differs (exit 12)"
repo="$(tf_release_repo pr23)"
tf_candidate "${repo}" patch
main23="$(git --git-dir="${TF_TMP}/pr23.git" rev-parse refs/heads/main)"
dev23="$(git --git-dir="${TF_TMP}/pr23.git" rev-parse refs/heads/develop)"
GIT_FAULT=push-tag-squatted RF_REAL_GIT="${REAL_GIT}" PATH="${SHIM_DIR}:${PATH}" RELEASE_FLOW_RECONCILE_DELAY=0 \
  promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 12 "PR23: a different remote tag exits 12"
assert_contains "${T_ERR}" "[T4] CONFLICT" "PR23: verdict CONFLICT"
assert_contains "${T_ERR}" "points to ${TF_B}, not ${TF_C}" "PR23: names both commits"
assert_eq "" "${T_OUT}" "PR23: stdout empty"
assert_eq "${TF_B}" "$(git --git-dir="${TF_TMP}/pr23.git" rev-parse refs/tags/0.1.1)" "PR23: the squatting tag is never moved or deleted"
assert_eq "${main23} ${dev23}" "$(git --git-dir="${TF_TMP}/pr23.git" rev-parse refs/heads/main) $(git --git-dir="${TF_TMP}/pr23.git" rev-parse refs/heads/develop)" "PR23: branches unchanged (atomic push rejected)"
assert_eq "absent" "$(exists "$(lock_path "${repo}")")" "PR23: lock released"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 3 "PR23: rerun is refused"
assert_contains "${T_ERR}" "[PF10] FAIL" "PR23: rerun fails PF10 (tag exists)"
assert_eq "${TF_B}" "$(git --git-dir="${TF_TMP}/pr23.git" rev-parse refs/tags/0.1.1)" "PR23: rerun leaves the tag alone"

t_case "PR24: Tag on C but main lacks C (exit 13)"
repo="$(tf_release_repo pr24)"
tf_candidate "${repo}" patch
main24="$(git --git-dir="${TF_TMP}/pr24.git" rev-parse refs/heads/main)"
GIT_FAULT=push-tag-only RF_REAL_GIT="${REAL_GIT}" PATH="${SHIM_DIR}:${PATH}" RELEASE_FLOW_RECONCILE_DELAY=0 \
  promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}"
assert_rc 13 "PR24: tag without branches exits 13"
assert_contains "${T_ERR}" "[T4] INCONSISTENT" "PR24: verdict INCONSISTENT"
assert_contains "${T_ERR}" "Manual repair required" "PR24: asks for manual repair"
assert_eq "" "${T_OUT}" "PR24: stdout empty"
assert_eq "$(git -C "${repo}" rev-parse refs/tags/0.1.1)" "$(git --git-dir="${TF_TMP}/pr24.git" rev-parse refs/tags/0.1.1)" "PR24: the remote tag is the local tag"
assert_eq "${TF_C}" "$(git --git-dir="${TF_TMP}/pr24.git" rev-parse 'refs/tags/0.1.1^{commit}')" "PR24: the tag peels to C"
assert_eq "${main24}" "$(git --git-dir="${TF_TMP}/pr24.git" rev-parse refs/heads/main)" "PR24: main does not contain C and is not repaired"
assert_eq "absent" "$(exists "$(lock_path "${repo}")")" "PR24: lock released"

t_case "PR25: Pinned pipeline evidence (PF13)"
P="0123456789abcdef0123456789abcdef01234567"
pr25_setup() {
  jq --arg sha "${P}" \
    '.pipeline = {repository: "nbari/release-flow", sha: $sha} | .promotion.required_job = "candidate / Candidate OK"' \
    .release-flow.json > .release-flow.json.tmp
  mv .release-flow.json.tmp .release-flow.json
}
TF_RELEASE_EXTRA_SETUP=pr25_setup
repo="$(tf_release_repo pr25)"
TF_RELEASE_EXTRA_SETUP=""
tf_candidate "${repo}" patch
e4="repos/acme/pr25/actions/workflows/candidate.yml/runs?head_sha=${TF_C}&event=push&per_page=100"
e5="repos/acme/pr25/actions/runs/${TF_RUN}/attempts/1/jobs?per_page=100"
tf_gh_edit "${e5}" '(.jobs[] | select(.name == "Candidate OK") | .name) = "candidate / Candidate OK"'
tf_gh_edit "repos/acme/pr25/rules/branches/main" '(.[] | select(.type == "required_status_checks") | .parameters.required_status_checks[0].context) = "candidate / Candidate OK"'
tf_gh_edit "${e4}" ".workflow_runs[0].referenced_workflows = [{path: \"nbari/release-flow/.github/workflows/candidate.yml@${P}\", sha: \"${P}\"}]"
cp "$(tf_gh_file "${e4}")" "${TF_TMP}/pr25-e4"
promote "${repo}" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
assert_rc 0 "PR25: dry run succeeds"
assert_eq "passed" "$(out_kv preflight)" "PR25: preflight=passed"
assert_contains "${T_ERR}" "pipeline nbari/release-flow@${P}" "PR25: pass text names the pin"
tf_gh_edit "${e4}" ".workflow_runs[0].referenced_workflows[0].path = \"nbari/release-flow/.github/workflows/candidate.yml@refs/tags/v1\""
assert_refused "${repo}" pr25 PF13 "must call exactly" "PR25 tag pin" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
cp "${TF_TMP}/pr25-e4" "$(tf_gh_file "${e4}")"
tf_gh_edit "${e4}" '.workflow_runs[0].referenced_workflows[0].sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
assert_refused "${repo}" pr25 PF13 "must call exactly" "PR25 sha differs" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
cp "${TF_TMP}/pr25-e4" "$(tf_gh_file "${e4}")"
tf_gh_edit "${e4}" ".workflow_runs[0].referenced_workflows[0].path = \"nbari/release-flow/.github/workflows/release.yml@${P}\""
assert_refused "${repo}" pr25 PF13 "must call exactly" "PR25 release.yml path" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
cp "${TF_TMP}/pr25-e4" "$(tf_gh_file "${e4}")"
tf_gh_edit "${e4}" '.workflow_runs[0].referenced_workflows = []'
assert_refused "${repo}" pr25 PF13 "found: none" "PR25 no referenced workflow" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
cp "${TF_TMP}/pr25-e4" "$(tf_gh_file "${e4}")"
tf_gh_edit "${e4}" ".workflow_runs[0].referenced_workflows = [{path: \"nbari/release-flow/.github/workflows/candidate.yml@${P}\", sha: \"${P}\"}, {path: \"nbari/release-flow/.github/workflows/release.yml@${P}\", sha: \"${P}\"}]"
assert_refused "${repo}" pr25 PF13 "must call exactly" "PR25 two entries" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run

t_case "PR26: Local config refuses a reusable run"
repo="$(tf_release_repo pr26)"
tf_candidate "${repo}" patch
e4="repos/acme/pr26/actions/workflows/candidate.yml/runs?head_sha=${TF_C}&event=push&per_page=100"
tf_gh_edit "${e4}" '.workflow_runs[0].referenced_workflows = [{path: "nbari/release-flow/.github/workflows/candidate.yml@0123456789abcdef0123456789abcdef01234567", sha: "0123456789abcdef0123456789abcdef01234567"}]'
assert_refused "${repo}" pr26 PF13 "declares no pipeline" "PR26 reusable run" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
jq '.pipeline = {repository: "nbari/release-flow", sha: "0123456789ab"}' "${repo}/.release-flow.json" > "${repo}/.release-flow.json.tmp"
mv "${repo}/.release-flow.json.tmp" "${repo}/.release-flow.json"
git -C "${repo}" add .release-flow.json
git -C "${repo}" commit --quiet -m "short pipeline sha"
assert_refused "${repo}" pr26 PF02 "invalid .release-flow.json at HEAD" "PR26 short sha" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run
jq '.pipeline = {repository: "nbari/release-flow", sha: "0123456789abcdef0123456789abcdef01234567", extra: true}' "${repo}/.release-flow.json" > "${repo}/.release-flow.json.tmp"
mv "${repo}/.release-flow.json.tmp" "${repo}/.release-flow.json"
git -C "${repo}" add .release-flow.json
git -C "${repo}" commit --quiet -m "unknown pipeline key"
assert_refused "${repo}" pr26 PF02 "invalid .release-flow.json at HEAD" "PR26 unknown pipeline key" --candidate "${TF_BRANCH}" --commit "${TF_C}" --dry-run

t_finish
