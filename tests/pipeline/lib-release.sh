#!/usr/bin/env bash
# Release (Milestone 2/3) fixtures. Source after lib.sh.
set -euo pipefail

TF_FIXTURES="${ROOT}/tests/pipeline/fixtures"
TF_MOCKBIN="${TF_TMP}/mockbin"
TF_CANDIDATE_SEQ=0
mkdir -p "${TF_MOCKBIN}"

export MOCK_GH_ROOT="${TF_TMP}/gh"
export MOCK_REGISTRY="${TF_TMP}/registry"
export MOCK_CARGO_LOG="${TF_TMP}/cargo.log"
export MOCK_CARGO_INDEX="${TF_TMP}/crates-index"  # tests point it at "${TF_TMP}/<name>-index"
export STUB_LOG="${TF_TMP}/stub-adapter.log"
mkdir -p "${MOCK_GH_ROOT}" "${MOCK_REGISTRY}" "${MOCK_CARGO_INDEX}"

# Paths installed by the release-flow bundle payload (except release-flow's own
# adapter): copied into release fixtures so they run the code under test.
tf_payload_paths() {
  (
    cd "${ROOT}"
    printf '%s\n' .justfiles/deploy.just .github/workflows/candidate.yml .github/workflows/release.yml
    find scripts -name '*.sh' ! -path 'scripts/adapters/*' \
      ! -name release-flow-bundle.sh ! -name release-flow-install.sh | LC_ALL=C sort
  )
}

# tf_signing_key: an unencrypted ed25519 SSH signing key (created once); prints
# the private key path.
tf_signing_key() {
  local key="${TF_TMP}/signing/${1:-tester}"
  if [[ ! -f "${key}" ]]; then
    mkdir -p "$(dirname "${key}")"
    ssh-keygen -q -t ed25519 -N '' -C "${1:-tester}@example.com" -f "${key}"
  fi
  printf '%s' "${key}"
}

tf_mock_gh_on() {
  ln -sf "${TF_FIXTURES}/mock-gh.sh" "${TF_MOCKBIN}/gh"
  case ":${PATH}:" in
    *":${TF_MOCKBIN}:"*) ;;
    *) PATH="${TF_MOCKBIN}:${PATH}"; export PATH ;;
  esac
}

tf_mock_tools_on() {
  ln -sf "${TF_FIXTURES}/mock-oras.sh" "${TF_MOCKBIN}/oras"
  ln -sf "${TF_FIXTURES}/mock-cargo.sh" "${TF_MOCKBIN}/cargo"
  tf_mock_gh_on
}

tf_gh_file() {
  printf '%s/api/%s' "${MOCK_GH_ROOT}" "$(printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g')"
}

# tf_gh_put <endpoint> <json>
tf_gh_put() {
  mkdir -p "${MOCK_GH_ROOT}/api"
  printf '%s\n' "$2" > "$(tf_gh_file "$1")"
}

# tf_gh_edit <endpoint> <jq-filter>
tf_gh_edit() {
  local f
  f="$(tf_gh_file "$1")"
  jq "$2" "${f}" > "${f}.tmp"
  mv "${f}.tmp" "${f}"
}

tf_gh_rm() {
  rm -f "$(tf_gh_file "$1")"
}

tf_gh_calls() {
  cat "${MOCK_GH_ROOT}/calls.log" 2>/dev/null || true
}

# tf_mock_protection_ok <repo>: rules for main/develop and an active tag ruleset.
tf_mock_protection_ok() {
  local r="$1"
  tf_gh_put "repos/${r}/rules/branches/main" '[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Candidate OK","integration_id":15368}]}}]'
  tf_gh_put "repos/${r}/rules/branches/develop" '[{"type":"deletion"},{"type":"non_fast_forward"}]'
  tf_gh_put "repos/${r}/rulesets?includes_parents=true&per_page=100" '[{"id":7,"name":"release-tags-immutable","target":"tag","enforcement":"active"}]'
  tf_gh_put "repos/${r}/rulesets/7" '{"id":7,"name":"release-tags-immutable","target":"tag","enforcement":"active","conditions":{"ref_name":{"include":["refs/tags/*.*.*","refs/tags/v*.*.*"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"update"},{"type":"non_fast_forward"}]}'
}

# tf_release_config <name>: the extended .release-flow.json of a release fixture.
tf_release_config() {
  local name="$1"
  jq -n --arg n "${name}" --arg store "file://${TF_TMP}/${name}-store" --arg index "file://${TF_TMP}/${name}-index" \
    --arg docs "file://${TF_TMP}/${name}-docs" --arg helm "file://${TF_TMP}/${name}-helm" '{
    schema_version: 1, project: $n, adapter: "tools/adapter.sh", remote: "origin",
    production_base: "develop", test_base: "sandbox",
    repository: ("acme/" + $n),
    promotion: {main_branch: "main", push_remote: "origin", candidate_workflow: ".github/workflows/candidate.yml",
                required_job: "Candidate OK", signature_verification: "allowed-signers",
                allowed_signers: ".github/release-flow/allowed_signers", publisher_ref: "main"},
    storage: {uri: $store},
    publishers: {
      "github-release": {required: true, assets: ["*"]},
      oci: {required: true, artifact: "stub-{version}-oci.tar", repository: ("ghcr.io/acme/" + $n), tags: ["{version}"], latest_tag: "latest"},
      "crates-io": {required: false, artifact: "stub-{version}.crate", package: "stub", index_url: $index},
      docs: {required: false, artifact: "stub-{version}-docs.tar.gz", uri: $docs, latest: true},
      helm: {required: false, artifact: "stub-chart-{version}.tgz", uri: $helm, base_url: "https://charts.example.com"}
    }}'
}

TF_RELEASE_NAME=""
TF_RELEASE_INSTALL="copy"

tf__release_setup() {
  local p key
  if [[ "${TF_RELEASE_INSTALL}" == "bundle" ]]; then
    bash "${TF_BUNDLE_ROOT}/install.sh" --target . >/dev/null 2>"${TF_TMP}/bundle-install.err" \
      || { cat "${TF_TMP}/bundle-install.err" >&2; return 1; }
  else
    while IFS= read -r p; do
      mkdir -p "$(dirname "${p}")"
      cp -p "${ROOT}/${p}" "${p}"
    done <<< "$(tf_payload_paths)"
  fi
  cat <<'EOF' > .justfile
import '.justfiles/deploy.just'

default:
    @echo root-default
EOF
  tf_release_config "${TF_RELEASE_NAME}" > .release-flow.json
  mkdir -p .github/release-flow
  : > .github/release-flow/allowed_signers
  for key in tester other; do
    printf '%s@example.com namespaces="git" %s\n' "${key}" "$(cut -d' ' -f1,2 "$(tf_signing_key "${key}").pub")" \
      >> .github/release-flow/allowed_signers
  done
  if [[ -n "${TF_RELEASE_EXTRA_SETUP:-}" ]]; then
    "${TF_RELEASE_EXTRA_SETUP}"
  fi
}

# tf_configure_signing <clone> [key-name]
tf_configure_signing() {
  local clone="$1" key
  key="$(tf_signing_key "${2:-tester}")"
  git -C "${clone}" config gpg.format ssh
  git -C "${clone}" config user.signingkey "${key}"
  git -C "${clone}" config gpg.ssh.allowedSignersFile "${TF_TMP}/allowed_signers"
  if [[ ! -f "${TF_TMP}/allowed_signers" ]]; then
    git -C "${clone}" show origin/main:.github/release-flow/allowed_signers > "${TF_TMP}/allowed_signers" 2>/dev/null \
      || cp "${clone}/.github/release-flow/allowed_signers" "${TF_TMP}/allowed_signers"
  fi
}

# tf_release_repo <name>: release fixture (bare remote acme/<name>, clone on
# sandbox) with the payload, extended config, allowed signers, signing set up,
# mock gh repository mapping and protection evidence.
tf_release_repo() {
  local name="$1" clone
  tf_signing_key tester >/dev/null
  tf_signing_key other >/dev/null
  TF_RELEASE_NAME="${name}"
  clone="$(tf_fixture_repo "${name}" 0.1.0 tf__release_setup)"
  tf_configure_signing "${clone}"
  mkdir -p "${MOCK_GH_ROOT}/remotes"
  printf '%s\n' "${TF_TMP}/${name}.git" > "${MOCK_GH_ROOT}/remotes/acme_${name}"
  tf_mock_protection_ok "acme/${name}"
  printf '%s' "${clone}"
}

# tf_clone <repo-name> <clone-name> [key-name]: another signed clone of the
# fixture's bare remote, on develop.
tf_clone() {
  local dir="${TF_TMP}/$2"
  git clone --quiet --branch develop "${TF_TMP}/$1.git" "${dir}"
  tf_configure_signing "${dir}" "${3:-tester}"
  printf '%s' "${dir}"
}

tf_kv() {
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# tf_candidate <repo> [bump] [--from <branch>]: prepares and pushes a candidate
# from develop (production) or another branch (test-only), then simulates its
# candidate CI (tf_candidate_ci).
tf_candidate() {
  local repo="$1" bump="patch" from="develop" mode out
  shift
  if [[ $# -gt 0 && "$1" != --* ]]; then bump="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      *) echo "tf_candidate: bad argument $1" >&2; return 2 ;;
    esac
  done
  if [[ "${from}" == "develop" ]]; then mode=production; else mode=test-only; fi
  out="$(cd "${repo}" && bash "${ROOT}/scripts/release-prepare.sh" "${bump}" --mode "${mode}" --base "${from}" --push 2>/dev/null)"
  tf_candidate_ci "${repo}" "$(tf_kv "${out}" candidate_branch)" "$(tf_kv "${out}" candidate_commit)"
}

# tf_candidate_ci <repo> <candidate-branch> <commit>: what candidate.yml does,
# locally: guard, inventory/package (STUB_ARTIFACTS=full), manifest (run id
# 1000+n, attempt 1), verify, mock GitHub evidence (runs, jobs, artifacts) and,
# for production candidates, retain-candidate into the fixture store.
# Exports TF_C TF_B TF_V TF_RUN TF_M TF_S TF_BRANCH TF_DIST TF_REPO_SLUG.
tf_candidate_ci() {
  local repo="$1" branch="$2" commit="$3" wt guard project version mode base base_branch adapter slug epoch inv
  TF_CANDIDATE_SEQ=$(( TF_CANDIDATE_SEQ + 1 ))
  TF_RUN=$(( 1000 + TF_CANDIDATE_SEQ ))
  wt="${TF_TMP}/ci-wt-${TF_RUN}"
  git -C "${repo}" worktree add --detach --quiet "${wt}" "${commit}"
  guard="$(cd "${wt}" && bash "${ROOT}/scripts/candidate-guard.sh" --ref "${branch}" --commit "${commit}")"
  project="$(tf_kv "${guard}" project)"
  version="$(tf_kv "${guard}" version)"
  mode="$(tf_kv "${guard}" mode)"
  base="$(tf_kv "${guard}" base_commit)"
  base_branch="$(tf_kv "${guard}" base_branch)"
  adapter="$(tf_kv "${guard}" adapter)"
  slug="$(jq -r .repository "${wt}/.release-flow.json")"
  epoch="$(git -C "${wt}" log -1 --format=%ct)"
  TF_DIST="${TF_TMP}/ci-dist-${TF_RUN}"
  inv="${TF_TMP}/ci-inv-${TF_RUN}.json"
  (cd "${wt}" && STUB_ARTIFACTS=full "./${adapter}" inventory "${version}" > "${inv}")
  (cd "${wt}" && SOURCE_DATE_EPOCH="${epoch}" STUB_ARTIFACTS=full "./${adapter}" package "${version}" "${TF_DIST}")
  TF_M="$(bash "${ROOT}/scripts/candidate-manifest.sh" --dir "${TF_DIST}" --inventory "${inv}" \
    --project "${project}" --repository "${slug}" --version "${version}" --mode "${mode}" \
    --base-branch "${base_branch}" --base-commit "${base}" --candidate-branch "${branch}" \
    --candidate-commit "${commit}" --run-id "${TF_RUN}" --run-attempt 1 --source-date-epoch "${epoch}" \
    --adapter "${adapter}")"
  bash "${ROOT}/scripts/verify-candidate.sh" --dir "${TF_DIST}" --commit "${commit}" --manifest-sha256 "${TF_M}" >/dev/null
  TF_S="$(sha256sum "${TF_DIST}/SHA256SUMS" | awk '{print $1}')"

  tf_gh_put "repos/${slug}/actions/workflows/candidate.yml/runs?head_sha=${commit}&event=push&per_page=100" "$(jq -nc \
    --argjson id "${TF_RUN}" --argjson n "${TF_CANDIDATE_SEQ}" --arg b "${branch}" --arg c "${commit}" --arg r "${slug}" \
    '{total_count: 1, workflow_runs: [{id: $id, run_number: $n, run_attempt: 1, name: "Candidate",
      path: ".github/workflows/candidate.yml", event: "push", head_branch: $b, head_sha: $c,
      status: "completed", conclusion: "success", repository: {full_name: $r}, head_repository: {full_name: $r}}]}')"
  tf_gh_put "repos/${slug}/actions/runs/${TF_RUN}/attempts/1/jobs?per_page=100" \
    '{"total_count":3,"jobs":[{"name":"Guard candidate identity","conclusion":"success"},{"name":"Verify downloaded candidate","conclusion":"success"},{"name":"Candidate OK","conclusion":"success"}]}'
  tf_gh_put "repos/${slug}/actions/runs/${TF_RUN}/artifacts?per_page=100" "$(jq -nc --arg n "candidate-${commit}-1" \
    '{total_count: 1, artifacts: [{id: 1, name: $n, expired: false}]}')"
  mkdir -p "${MOCK_GH_ROOT}/artifacts/${TF_RUN}/candidate-${commit}-1"
  cp -p "${TF_DIST}"/* "${MOCK_GH_ROOT}/artifacts/${TF_RUN}/candidate-${commit}-1/"

  if [[ "${mode}" == "production" ]]; then
    bash "${ROOT}/scripts/storage/storage.sh" --uri "$(jq -r .storage.uri "${wt}/.release-flow.json")" \
      retain-candidate --dir "${TF_DIST}" --manifest-sha256 "${TF_M}" --repository "${slug}" --run-id "${TF_RUN}" >/dev/null
  fi
  git -C "${repo}" worktree remove --force "${wt}"
  TF_C="${commit}"
  TF_B="${base}"
  TF_V="${version}"
  TF_BRANCH="${branch}"
  TF_REPO_SLUG="${slug}"
  export TF_C TF_B TF_V TF_RUN TF_M TF_S TF_BRANCH TF_DIST TF_REPO_SLUG
}

# tf_tag_message <project> <repository> <storage-uri>: the signed tag message
# for the current TF_* candidate. Encoded here on purpose (not taken from
# scripts/lib/tag.sh) so format drift is caught.
tf_tag_message() {
  cat <<EOF
release-flow $1 ${TF_V}

Promoted by release-flow.

Release-Project: $1
Release-Repository: $2
Release-Version: ${TF_V}
Release-Commit: ${TF_C}
Release-Base-Commit: ${TF_B}
Release-Candidate-Branch: ${TF_BRANCH}
Release-Candidate-Run: ${TF_RUN}
Release-Candidate-Run-Attempt: 1
Release-Manifest-SHA256: ${TF_M}
Release-SHA256SUMS-SHA256: ${TF_S}
Release-Storage: $3
EOF
}

# tf_promoted_release <repo> [bump]: candidate, signed tag and one atomic push
# of main, develop and the tag, without release-promote.sh. Exports TF_T.
tf_promoted_release() {
  local repo="$1" bump="${2:-patch}" cfg
  tf_candidate "${repo}" "${bump}"
  cfg="$(git -C "${repo}" show "${TF_C}:.release-flow.json")"
  tf_tag_message "$(printf '%s' "${cfg}" | jq -r .project)" "$(printf '%s' "${cfg}" | jq -r .repository)" \
    "$(printf '%s' "${cfg}" | jq -r .storage.uri)" > "${TF_TMP}/tag-msg-${TF_V}"
  git -C "${repo}" tag -s -a "${TF_V}" -F "${TF_TMP}/tag-msg-${TF_V}" "${TF_C}"
  git -C "${repo}" push --quiet --atomic origin "${TF_C}:refs/heads/main" "${TF_C}:refs/heads/develop" "refs/tags/${TF_V}:refs/tags/${TF_V}"
  TF_T="$(git -C "${repo}" rev-parse "refs/tags/${TF_V}")"
  export TF_T
}

tf_remote_refs() {
  git ls-remote "$1" | sort
}

tf_store() {
  printf '%s/%s-store' "${TF_TMP}" "$1"
}

tf_blob_path() {
  printf '%s/blobs/sha256/%s/%s' "$(tf_store "$1")" "${2:0:2}" "$2"
}

# tf_artifact_sha <name>: sha256 of an artifact of the current TF_* candidate.
tf_artifact_sha() {
  jq -r --arg n "$1" '.artifacts[] | select(.name == $n) | .sha256' "${TF_DIST}/manifest.json"
}
