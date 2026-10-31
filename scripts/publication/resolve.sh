#!/usr/bin/env bash
# Resolve a promoted release into verified local bytes.
#
#   resolve.sh [--project-dir DIR] --version X.Y.Z --out DIR
#
# 1. The remote tag X.Y.Z must exist (else exit 4 "not promoted").
# 2. Its objects are fetched without writing any ref.
# 3. The tag must be an annotated tag whose strict trailers name this
#    project, repository, version and commit, carrying a valid signature
#    (promotion.signature_verification), and the commit must be contained in
#    the remote main branch (else exit 3).
#    From here the identity is known: DIR/binding.json is written.
# 4. The release binding releases/<P>/<V>.json is stored (create-only; a
#    different existing binding exits 5).
# 5. The stored candidate record must equal the tag's trailers (else exit 6).
# 6. All blobs are materialized into DIR/artifacts and verified against the
#    pinned manifest digest (missing exit 4, mismatch exit 6).
# On success DIR/release.json holds the binding.
#
# The configuration (destinations, storage) comes from the checkout running
# this script; the identity comes only from the signed tag.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"
# shellcheck source=scripts/lib/github.sh
source "${RF_SCRIPTS}/lib/github.sh"
# shellcheck source=scripts/lib/tag.sh
source "${RF_SCRIPTS}/lib/tag.sh"

usage() {
  echo "Usage: resolve.sh [--project-dir DIR] --version X.Y.Z --out DIR" >&2
  exit 2
}

project_dir="."
version=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    --out) [[ $# -ge 2 ]] || usage; out="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "${version}" && -n "${out}" ]] || usage
rf_semver_valid "${version}" || rf_die "Invalid version: ${version}" 2

top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || rf_die "Not inside a Git work tree: ${project_dir}" 2
cd "${top}"
mkdir -p "${out}"
out="$(cd "${out}" && pwd)"
[[ ! -e "${out}/release.json" && ! -e "${out}/artifacts" ]] || rf_die "resolve: output directory already holds a resolved release: ${out}" 2

[[ -f .release-flow.json ]] || rf_die "resolve: missing .release-flow.json in ${top}" 3
rf_schema_check config .release-flow.json || rf_die "resolve: invalid .release-flow.json" 3
rf_config_load_text "$(cat .release-flow.json)"
rf_git_auth_env

project="$(rf_cfg .project)"
repository="$(rf_cfg .repository)"
[[ -n "${repository}" ]] || rf_die "resolve: .release-flow.json lacks \"repository\"" 3
remote="$(rf_cfg .promotion.push_remote)"
[[ -n "${remote}" ]] || remote="$(rf_cfg .remote)"
main_branch="$(rf_cfg .promotion.main_branch)"
[[ -n "${main_branch}" ]] || main_branch="main"
mode="$(rf_cfg .promotion.signature_verification)"
[[ -n "${mode}" ]] || mode="github"
storage_uri="$(rf_storage_uri)"
[[ -n "${storage_uri}" ]] || rf_die "resolve: storage not configured" 3

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# 1. Remote tag
if ! ls="$(git ls-remote "${remote}" "refs/tags/${version}" "refs/tags/${version}^{}" "refs/heads/${main_branch}")"; then
  rf_die "resolve: cannot query ${remote}" 1
fi
tag_obj="$(rf_ls_remote_value "${ls}" "refs/tags/${version}")"
commit="$(rf_ls_remote_value "${ls}" "refs/tags/${version}^{}")"
main_sha="$(rf_ls_remote_value "${ls}" "refs/heads/${main_branch}")"
[[ -n "${tag_obj}" ]] || rf_die "resolve: ${version} is not promoted (no tag ${version} on ${remote})" 4
[[ -n "${commit}" ]] || rf_die "resolve: tag ${version} on ${remote} is not an annotated tag" 3
[[ -n "${main_sha}" ]] || rf_die "resolve: ${remote} has no ${main_branch} branch" 3

# 2. Objects only; no ref is written
rf_git_fetch "${remote}" "refs/tags/${version}" "refs/heads/${main_branch}" \
  || rf_die "resolve: cannot fetch tag ${version} from ${remote}" 1

# 3. Strict identity from the signed tag
if ! rf_tag_parse "${tag_obj}" > "${WORK}/record.json"; then
  rf_die "resolve: tag ${version} is not a valid release-flow promotion tag" 3
fi
if ! jq -e --arg p "${project}" --arg r "${repository}" --arg v "${version}" --arg c "${commit}" \
     '.project == $p and .repository == $r and .version == $v and .candidate_commit == $c' "${WORK}/record.json" >/dev/null; then
  rf_die "resolve: tag ${version} binds $(jq -r '.project + " " + .repository + " " + .version + " " + .candidate_commit' "${WORK}/record.json"), not ${project} ${repository} ${version} ${commit}" 3
fi
if ! rf_tag_verify_signature "${tag_obj}" "${mode}" "${repository}" "${commit}" "$(rf_cfg .promotion.allowed_signers)"; then
  rf_die "resolve: tag ${version} signature is not trusted (${mode}); refusing to publish" 3
fi
if ! git merge-base --is-ancestor "${commit}" "${main_sha}"; then
  rf_die "resolve: ${commit} is not contained in ${remote}/${main_branch}; the release is inconsistent" 3
fi

jq --arg t "${version}" --arg o "${tag_obj}" --arg u "${storage_uri}" \
  '. + {kind: "release-binding", tag: $t, tag_object: $o, storage_uri: $u}' "${WORK}/record.json" > "${WORK}/binding.json"
rf_schema_check release-binding "${WORK}/binding.json" || rf_die "resolve: internal error: invalid release binding" 1
cp "${WORK}/binding.json" "${out}/binding.json"

# 4. Durable binding (create-only)
rc=0
rf_storage put-record "releases/${project}/${version}.json" "${WORK}/binding.json" --kind release-binding || rc=$?
case "${rc}" in
  0) ;;
  5) rf_die "resolve: a different release binding is stored for ${project} ${version}" 5 ;;
  *) rf_die "resolve: cannot store the release binding" 1 ;;
esac

# 5. Candidate record equals the tag
m="$(jq -r .manifest_sha256 "${WORK}/binding.json")"
run="$(jq -r .run_id "${WORK}/binding.json")"
attempt="$(jq -r .run_attempt "${WORK}/binding.json")"
key="candidates/${project}/${commit}/${run}-${attempt}.json"
rc=0
rf_storage get-record "${key}" "${WORK}/candidate.json" --kind candidate-record || rc=$?
case "${rc}" in
  0) ;;
  4) rf_die "resolve: candidate record ${key} is missing; the source cannot be recovered and will not be rebuilt" 4 ;;
  6) rf_die "resolve: candidate record ${key} is corrupt" 6 ;;
  *) rf_die "resolve: cannot read candidate record ${key}" 1 ;;
esac
if ! jq -e --slurpfile b "${WORK}/binding.json" '
     . as $c | $b[0] as $b
     | all(["project","repository","version","candidate_commit","base_commit","candidate_branch",
            "run_id","run_attempt","manifest_sha256","sha256sums_sha256"][]; $c[.] == $b[.])' \
     "${WORK}/candidate.json" >/dev/null; then
  rf_die "resolve: integrity failure: stored candidate record ${key} (manifest $(jq -r .manifest_sha256 "${WORK}/candidate.json")) differs from tag ${version} (manifest ${m})" 6
fi

# 6. Materialize and verify the exact bytes
rc=0
rf_storage materialize --record "${key}" --out "${out}/artifacts" || rc=$?
case "${rc}" in
  0) ;;
  4) rf_die "resolve: source artifacts of ${version} are missing from storage; they will not be rebuilt" 4 ;;
  6) rf_die "resolve: integrity failure: stored artifacts of ${version} do not match manifest ${m}" 6 ;;
  *) rf_die "resolve: cannot materialize ${version}" 1 ;;
esac
if ! bash "${RF_SCRIPTS}/verify-candidate.sh" --dir "${out}/artifacts" --commit "${commit}" --version "${version}" \
     --mode production --base-commit "$(jq -r .base_commit "${WORK}/binding.json")" --project "${project}" \
     --repository "${repository}" --run-id "${run}" --manifest-sha256 "${m}" >/dev/null; then
  rf_die "resolve: integrity failure: materialized artifacts fail verification" 6
fi
cp "${WORK}/binding.json" "${out}/release.json"
rf_kv version "${version}"
rf_kv candidate_commit "${commit}"
rf_kv tag_object "${tag_obj}"
rf_kv manifest_sha256 "${m}"
