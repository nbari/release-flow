#!/usr/bin/env bash
# End-to-end release flow through `just` in a bundle-installed repository:
# deploy -> candidate CI evidence -> promote -> publish -> status; concurrent
# retries; recovery from a broken tag-time publisher with current code; and the
# bundle/workflow contract.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pipeline/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

orig_dir="$(pwd)"
tf_mock_tools_on

kv() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

exists() {
  if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

release_count() {
  local d n=0
  for d in "${MOCK_GH_ROOT}/releases/acme_$1"/*/; do
    [[ -f "${d}meta.json" ]] || continue
    [[ "$(jq -r .tag_name "${d}meta.json")" == "$2" ]] && n=$(( n + 1 ))
  done
  echo "${n}"
}

release_dir() {
  local d
  for d in "${MOCK_GH_ROOT}/releases/acme_$1"/*/; do
    if [[ -f "${d}meta.json" && "$(jq -r .tag_name "${d}meta.json")" == "$2" ]]; then
      printf '%s' "${d%/}"
      return 0
    fi
  done
  return 1
}

bundle_out="${TF_TMP}/bundle-out"
bundle_archive="$(bash "${ROOT}/scripts/release-flow-bundle.sh" --version 9.9.9 --out "${bundle_out}" 2>/dev/null)"
tar -xzf "${bundle_archive}" -C "${bundle_out}"
export TF_BUNDLE_ROOT="${bundle_out}/release-flow-bundle-9.9.9"

# ---------------------------------------------------------------------------

t_case "IN01: End to end through just"
TF_RELEASE_INSTALL=bundle
repo="$(tf_release_repo in01)"
TF_RELEASE_INSTALL=copy
bare="${TF_TMP}/in01.git"
sandbox_before="$(git ls-remote "${bare}" refs/heads/sandbox)"
cd "${repo}"
git checkout --quiet develop
t_run just deploy
assert_rc 0 "IN01: just deploy from develop"
branch="$(kv "${T_OUT}" candidate_branch)"
commit="$(kv "${T_OUT}" candidate_commit)"
assert_eq "production" "$(kv "${T_OUT}" mode)" "IN01: production candidate"
t_run just release-status 0.1.1 --json
assert_eq "PREPARED" "$(printf '%s' "${T_OUT}" | jq -r .state)" "IN01: PREPARED before candidate CI"
tf_candidate_ci "${repo}" "${branch}" "${commit}"
t_run just release-status 0.1.1 --json
assert_eq "VALIDATED" "$(printf '%s' "${T_OUT}" | jq -r .state)" "IN01: VALIDATED after candidate CI and retention"
assert_eq "${commit}" "$(printf '%s' "${T_OUT}" | jq -r .candidate_commit)" "IN01: status names the candidate commit"
packages_after_ci="$(grep -c '^package$' "${STUB_LOG}" || true)"
tf_forbid_toolchains
t_run just release-promote "${branch}" "${commit}"
assert_rc 0 "IN01: just release-promote"
assert_eq "PROMOTED" "$(kv "${T_OUT}" state)" "IN01: promoted"
assert_eq "${commit}" "$(git --git-dir="${bare}" rev-parse 'refs/tags/0.1.1^{commit}')" "IN01: tag 0.1.1 -> C"
t_run just release-status 0.1.1 --json
assert_rc 0 "IN01: status after promotion"
assert_eq "PROMOTED" "$(printf '%s' "${T_OUT}" | jq -r .state)" "IN01: PROMOTED before publishing"
t_run just release-retry 0.1.1 github-release --local
assert_rc 0 "IN01: just release-retry github-release --local"
assert_contains "${T_OUT}" "state=succeeded" "IN01: github-release succeeded"
t_run just release-retry 0.1.1 oci --local
assert_rc 0 "IN01: just release-retry oci --local"
t_run just release-status 0.1.1 --json
assert_rc 0 "IN01: status after publishing"
assert_eq "PUBLISHED" "$(printf '%s' "${T_OUT}" | jq -r .state)" "IN01: PUBLISHED"
assert_eq "succeeded succeeded" "$(printf '%s' "${T_OUT}" | jq -r '[.channels["github-release"].state, .channels.oci.state] | join(" ")')" "IN01: both required channels succeeded"
assert_eq "pending" "$(printf '%s' "${T_OUT}" | jq -r '.channels.docs.state')" "IN01: optional channel pending does not block PUBLISHED"
assert_eq "true" "$(printf '%s' "${T_OUT}" | jq -r '.binding')" "IN01: release binding stored"
assert_eq "${TF_M}" "$(printf '%s' "${T_OUT}" | jq -r '.manifest_sha256')" "IN01: status reports the manifest digest"
assert_contains "${T_ERR}" "github-release" "IN01: human table on stderr"
assert_eq "${sandbox_before}" "$(git ls-remote "${bare}" refs/heads/sandbox)" "IN01: sandbox untouched"
assert_eq "${packages_after_ci}" "$(grep -c '^package$' "${STUB_LOG}" || true)" "IN01: nothing packaged after candidate creation"
assert_eq "absent" "$(exists "${TF_TMP}/forbidden-tools.log")" "IN01: no toolchain invoked"
t_run just release-status 9.9.9
assert_rc 4 "IN01: unknown version exits 4"
cd "${orig_dir}"
PATH="${PATH#"${TF_TMP}/shims:"}"

t_case "IN02: Concurrent retries of the same channel"
repo="$(tf_release_repo in02)"
tf_promoted_release "${repo}" patch
: > "${MOCK_GH_ROOT}/calls.log"
for n in 1 2; do
  (
    rc=0
    bash "${repo}/scripts/release-retry.sh" --project-dir "${repo}" 0.1.1 github-release --local \
      > "${TF_TMP}/in02-${n}.out" 2> "${TF_TMP}/in02-${n}.err" || rc=$?
    echo "${rc}" > "${TF_TMP}/in02-${n}.rc"
  ) &
done
wait
codes="$(cat "${TF_TMP}/in02-1.rc" "${TF_TMP}/in02-2.rc" | sort -n | tr '\n' ' ' | sed 's/ $//')"
if [[ "${codes}" == "0 9" || "${codes}" == "0 0" ]]; then codes_ok=yes; else codes_ok="no (${codes})"; fi
assert_eq "yes" "${codes_ok}" "IN02: exit codes are {0, 9} or {0, 0}"
assert_eq "1" "$(release_count in02 0.1.1)" "IN02: exactly one release"
assert_eq "false" "$(jq -r .draft "$(release_dir in02 0.1.1)/meta.json")" "IN02: the release is published"
assert_eq "1" "$(grep -c '^gh release create 0.1.1 ' "${MOCK_GH_ROOT}/calls.log" || true)" "IN02: one draft-create call"
assert_eq "succeeded" "$(bash "${ROOT}/scripts/publication/ledger.sh" --uri "file://$(tf_store in02)" status --project in02 --version 0.1.1 --channel github-release | jq -r '.channels["github-release"].state')" "IN02: ledger's latest event is succeeded"
assert_eq "absent" "$(exists "$(tf_store in02)/locks/in02/0.1.1/github-release.json")" "IN02: no lock left behind"

t_case "IN03: Recovery with current publisher code"
in03_broken_publisher() {
  printf '#!/usr/bin/env bash\necho "tag-time publisher bug" >&2\nexit 1\n' > scripts/publishers/github-release.sh
}
TF_RELEASE_EXTRA_SETUP=in03_broken_publisher
repo="$(tf_release_repo in03)"
TF_RELEASE_EXTRA_SETUP=""
tf_promoted_release "${repo}" patch
tag_before="$(git --git-dir="${TF_TMP}/in03.git" rev-parse refs/tags/0.1.1)"
tag_wt="${TF_TMP}/in03-tag"
git -C "${repo}" worktree add --detach --quiet "${tag_wt}" refs/tags/0.1.1
t_run bash "${tag_wt}/scripts/publication/publish.sh" --project-dir "${tag_wt}" --version 0.1.1 --channel github-release
assert_rc 1 "IN03: the publisher frozen at the tag fails"
assert_contains "${T_ERR}" "tag-time publisher bug" "IN03: the tag-time bug is what failed"
git -C "${repo}" worktree remove --force "${tag_wt}"
cd "${repo}"
git checkout --quiet develop
git fetch --quiet origin
git merge --quiet --ff-only origin/develop
cp "${ROOT}/scripts/publishers/github-release.sh" scripts/publishers/github-release.sh
git commit --quiet -am "Fix the GitHub Release publisher"
git push --quiet origin develop
cd "${orig_dir}"
t_run bash "${repo}/scripts/release-retry.sh" --project-dir "${repo}" 0.1.1 github-release --local
assert_rc 0 "IN03: retry with the fixed develop code succeeds"
assert_eq "${tag_before}" "$(git --git-dir="${TF_TMP}/in03.git" rev-parse refs/tags/0.1.1)" "IN03: same tag object"
assert_eq "0.1.1" "$(git ls-remote --tags --refs "${TF_TMP}/in03.git" | sed 's|.*refs/tags/||' | tr '\n' ' ' | sed 's/ $//')" "IN03: no new tags or versions"
rel="$(release_dir in03 0.1.1)"
assert_eq "$(cd "${TF_DIST}" && for f in *; do printf '%s %s\n' "${f}" "$(sha256sum "${f}" | awk '{print $1}')"; done)" \
  "$(cd "${rel}/assets" && for f in *; do printf '%s %s\n' "${f}" "$(sha256sum "${f}" | awk '{print $1}')"; done)" "IN03: the original artifacts are published"
: > "${MOCK_GH_ROOT}/calls.log"
t_run bash "${repo}/scripts/release-retry.sh" --project-dir "${repo}" 0.1.1 github-release
assert_rc 0 "IN03: dispatched retry"
assert_contains "${T_OUT}" "mode=dispatched" "IN03: reports a dispatch"
assert_contains "$(cat "${MOCK_GH_ROOT}/calls.log")" "gh workflow run release.yml --repo acme/in03 --ref main -f version=0.1.1 -f channel=github-release" "IN03: dispatches release.yml on main for the same version"
t_run bash "${repo}/scripts/release-retry.sh" --project-dir "${repo}" 0.9.9 github-release
assert_rc 4 "IN03: retry of an unpromoted version exits 4"
t_run bash "${repo}/scripts/release-retry.sh" --project-dir "${repo}" 0.1.1 bogus
assert_rc 2 "IN03: unknown channel exits 2"

t_case "IN04: Bundle and workflow contract"
assert_eq "30" "$(jq '.payload | length' "${TF_BUNDLE_ROOT}/BUNDLE.json")" "IN04: the bundle carries all 30 payload files"
missing=0
while IFS= read -r p; do
  [[ -f "${TF_BUNDLE_ROOT}/payload/${p}" ]] || missing=$(( missing + 1 ))
done <<< "$(jq -r '.payload[].path' "${TF_BUNDLE_ROOT}/BUNDLE.json")"
assert_eq "0" "${missing}" "IN04: every payload file is in the archive"
cd "${TF_TMP}/in01"
t_run just --list
for recipe in deploy deploy-minor deploy-major release-promote release-status release-retry; do
  assert_contains "${T_OUT}" "    ${recipe} " "IN04: installed justfile lists ${recipe}"
done
cd "${orig_dir}"
assert_eq "present" "$(exists "${ROOT}/.github/workflows/release.yml")" "IN04: release.yml is present"
assert_eq "absent" "$(exists "${ROOT}/.github/actions/release-is-latest")" "IN04: release-is-latest action is gone"
assert_eq "" "$(grep -nE '^[[:space:]]+needs:' "${ROOT}/.github/workflows/release.yml" || true)" "IN04: release.yml has no needs"
assert_eq "" "$(grep -rlE 'release\.env|Candidate run:' "${ROOT}/.github" "${ROOT}/scripts" || true)" "IN04: no release.env or free-form tag parsing"
assert_eq "" "$(grep -rnE '^[[:space:]]*(source|\.)[[:space:]]' "${ROOT}/scripts" "${ROOT}/.github/workflows" \
  | grep -vE ':[0-9]+:[[:space:]]*\.[[:space:]]+as[[:space:]]' \
  | grep -vE '/(lib|storage/backends)/[a-z0-9]+\.sh"$' || true)" "IN04: nothing but release-flow's own libraries is ever sourced"

t_finish
