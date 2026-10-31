#!/usr/bin/env bash
# Guarded, atomic production promotion of a validated release candidate.
#
#   release-promote.sh [--project-dir DIR] --candidate release/X.Y.Z-<base12> --commit <40-hex> [--dry-run]
#
# Decide (PF01-PF20, read-only): the exact candidate commit, its production
# trailers and topology, that it edits no release tooling, the remote state,
# the GitHub evidence (workflow run, required job, artifact), the downloaded
# manifest, the durable storage record and blobs, signing readiness and the
# server-side protection rules. Act: create (or reuse) the signed tag X.Y.Z,
# re-check the remote, then ONE `git push --atomic` of main, the production base
# and the tag (fast-forward and create-only; never forced). Reconcile: observe
# the remote and classify the outcome, whatever the push reported.
#
# Never builds, never force-pushes, never deletes or moves tags.
#
# stdout (key=value, in order): project version tag tag_object candidate_branch
#   candidate_commit base_commit run_id run_attempt manifest_sha256 main_before
#   state already_promoted promoted_by_other reconciled
# --dry-run prints preflight=passed plus the identity keys.
# stderr: one "[PFnn] PASS|FAIL <detail>" line per check, then progress.
#
# Exit codes: 0 promoted (or already promoted), 1 environment/transient,
# 2 usage, 3 precondition rejected (nothing changed), 9 another promotion is
# running, 10 push rejected (remote unchanged; rerun reuses the local tag),
# 11 push outcome unknown (remote unreachable; rerun reconciles first),
# 12 version promoted with a different identity, 13 inconsistent remote refs,
# 14 promoted but GitHub reports the tag signature unverified.
#
# Tuning: RELEASE_FLOW_RECONCILE_ATTEMPTS (default 5),
# RELEASE_FLOW_RECONCILE_DELAY (seconds, default 2, doubled per retry),
# RELEASE_FLOW_STORAGE_URI (overrides storage.uri).
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"
# shellcheck source=scripts/lib/github.sh
source "${RF_SCRIPTS}/lib/github.sh"
# shellcheck source=scripts/lib/tag.sh
source "${RF_SCRIPTS}/lib/tag.sh"

usage() {
  cat <<'EOF' >&2
Usage: release-promote.sh [--project-dir DIR] --candidate release/X.Y.Z-<base12> --commit <40-hex> [--dry-run]
EOF
  exit 2
}

project_dir="."
candidate=""
commit=""
dry_run=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --candidate) [[ $# -ge 2 ]] || usage; candidate="$2"; shift 2 ;;
    --commit) [[ $# -ge 2 ]] || usage; commit="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    *) usage ;;
  esac
done
[[ -n "${candidate}" && -n "${commit}" ]] || usage

if ! top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || [[ -z "${top}" ]]; then
  rf_die "Not inside a Git work tree: ${project_dir}" 2
fi
cd "${top}"

WORK="$(mktemp -d)"
lock_dir=""
rf_dir=""

cleanup() {
  local r
  for r in $(git for-each-ref --format='%(refname)' refs/release-flow/remote/ 2>/dev/null); do
    git update-ref -d "${r}" 2>/dev/null || true
  done
  rm -rf "${WORK}"
  if [[ -n "${lock_dir}" ]]; then
    rf_lock_release "${lock_dir}"
  fi
  if [[ -n "${rf_dir}" ]]; then
    rmdir "${rf_dir}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pf_pass() {
  printf '[%s] PASS %s\n' "$1" "$2" >&2
}

# pf_fail <check> <detail> [exit-code]
pf_fail() {
  printf '[%s] FAIL %s\n' "$1" "$2" >&2
  exit "${3:-3}"
}

# ---------------------------------------------------------------------------
# Phase 1: Decide (PF01-PF20; read-only apart from the private fetch refs)
# ---------------------------------------------------------------------------

# PF01 tools
rf_git_version_ok 2 31 || pf_fail PF01 "git >= 2.31 required (found: $(git --version 2>/dev/null))" 1
for tool in jq gh; do
  command -v "${tool}" >/dev/null 2>&1 || pf_fail PF01 "missing required tool: ${tool}" 1
done
rf_have_sha256 || pf_fail PF01 "missing required tool: sha256sum or shasum" 1
gh auth status >/dev/null 2>&1 || pf_fail PF01 "gh is not authenticated (run: gh auth login)" 1
pf_pass PF01 "git $(git --version | awk '{print $3}'), jq, gh (authenticated), sha256"

# PF02 bootstrap configuration from HEAD
boot_cfg="${WORK}/boot-config.json"
git show HEAD:.release-flow.json > "${boot_cfg}" 2>/dev/null || pf_fail PF02 "missing .release-flow.json at HEAD"
rf_schema_check config "${boot_cfg}" || pf_fail PF02 "invalid .release-flow.json at HEAD"
rf_config_load_text "$(cat "${boot_cfg}")" || pf_fail PF02 "invalid .release-flow.json at HEAD"
[[ -n "$(rf_cfg .repository)" ]] || pf_fail PF02 ".release-flow.json lacks \"repository\" (owner/name)"
[[ -n "$(rf_cfg .promotion)" ]] || pf_fail PF02 ".release-flow.json lacks the \"promotion\" block"
push_remote="$(rf_cfg .promotion.push_remote)"
[[ -n "${push_remote}" ]] || push_remote="$(rf_cfg .remote)"
main_branch="$(rf_cfg .promotion.main_branch)"
[[ -n "${main_branch}" ]] || main_branch="main"
prod_base="$(rf_cfg .production_base)"
git remote get-url "${push_remote}" >/dev/null 2>&1 || pf_fail PF02 "push remote '${push_remote}' is not configured in this clone"
pf_pass PF02 "config at HEAD: push remote ${push_remote}, ${main_branch} <- ${prod_base}"

# PF03 exclusive local promotion lock
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
rf_dir="${common_dir}/release-flow"
if ! rf_lock_acquire "${rf_dir}/promote.lock" promotion; then
  pf_fail PF03 "another promotion is running in this clone" 9
fi
lock_dir="${rf_dir}/promote.lock"
pf_pass PF03 "promotion lock ${lock_dir}"

# PF04 fresh remote snapshot and the already-promoted fast path
version=""
base12=""
if [[ "${candidate}" =~ ^release/([0-9]+\.[0-9]+\.[0-9]+)-([0-9a-f]{12})$ ]]; then
  version="${BASH_REMATCH[1]}"
  base12="${BASH_REMATCH[2]}"
fi
if ! rf_git_fetch "${push_remote}" \
     "+refs/heads/${main_branch}:refs/release-flow/remote/main" \
     "+refs/heads/${prod_base}:refs/release-flow/remote/develop"; then
  pf_fail PF04 "cannot fetch ${main_branch} and ${prod_base} from ${push_remote}" 1
fi
cand_tip=""
if git check-ref-format --branch "${candidate}" >/dev/null 2>&1 && [[ "${candidate}" == release/* ]]; then
  if rf_git_fetch "${push_remote}" \
       "+refs/heads/${candidate}:refs/release-flow/remote/candidate" 2>/dev/null; then
    cand_tip="$(git rev-parse --verify refs/release-flow/remote/candidate)"
  fi
fi
if ! ls_tags="$(git ls-remote --tags "${push_remote}")"; then
  pf_fail PF04 "cannot list tags on ${push_remote}" 1
fi
main_before="$(git rev-parse --verify refs/release-flow/remote/main)"
develop_before="$(git rev-parse --verify refs/release-flow/remote/develop)"
tag_before="absent"
if [[ -n "${version}" ]]; then
  tag_before="$(rf_ls_remote_value "${ls_tags}" "refs/tags/${version}")"
  [[ -n "${tag_before}" ]] || tag_before="absent"
fi

mode="$(rf_cfg .promotion.signature_verification)"
[[ -n "${mode}" ]] || mode="github"
repository="$(rf_cfg .repository)"

# emit_result <record-json-file> <tag-object> <state> <already> <by_other> <reconciled>
emit_result() {
  local rec="$1"
  rf_kv project "$(jq -r .project "${rec}")"
  rf_kv version "$(jq -r .version "${rec}")"
  rf_kv tag "$(jq -r .version "${rec}")"
  rf_kv tag_object "$2"
  rf_kv candidate_branch "$(jq -r .candidate_branch "${rec}")"
  rf_kv candidate_commit "$(jq -r .candidate_commit "${rec}")"
  rf_kv base_commit "$(jq -r .base_commit "${rec}")"
  rf_kv run_id "$(jq -r .run_id "${rec}")"
  rf_kv run_attempt "$(jq -r .run_attempt "${rec}")"
  rf_kv manifest_sha256 "$(jq -r .manifest_sha256 "${rec}")"
  rf_kv main_before "${main_before}"
  rf_kv state "$3"
  rf_kv already_promoted "$4"
  rf_kv promoted_by_other "$5"
  rf_kv reconciled "$6"
}

if [[ "${tag_before}" != "absent" && "${commit}" =~ ${RF_RE_COMMIT} ]]; then
  peeled="$(rf_ls_remote_value "${ls_tags}" "refs/tags/${version}^{}")"
  if [[ "${peeled}" == "${commit}" ]] && \
     rf_git_fetch "${push_remote}" \
       "+refs/tags/${version}:refs/release-flow/remote/tag" 2>/dev/null && \
     rf_tag_parse "${tag_before}" > "${WORK}/remote-record.json" 2>/dev/null && \
     [[ "$(jq -r .candidate_commit "${WORK}/remote-record.json")" == "${commit}" ]] && \
     git merge-base --is-ancestor "${commit}" "${main_before}" && \
     git merge-base --is-ancestor "${commit}" "${develop_before}" && \
     rf_tag_verify_signature "${tag_before}" "${mode}" "${repository}" "${commit}" \
       "$(rf_cfg .promotion.allowed_signers)" 2>/dev/null; then
    pf_pass PF04 "${version} is already promoted: tag ${tag_before} -> ${commit}, contained in ${main_branch} and ${prod_base}"
    emit_result "${WORK}/remote-record.json" "${tag_before}" PROMOTED true false false
    echo "Release ${version} is already promoted; nothing to do." >&2
    exit 0
  fi
fi
pf_pass PF04 "snapshot ${main_branch}=${main_before:0:12} ${prod_base}=${develop_before:0:12} tag ${version:-?}=${tag_before}"

# PF05 production candidate branch
if [[ "${candidate}" == release/test/* ]]; then
  pf_fail PF05 "${candidate}: test-only candidates are never promotable"
fi
[[ -n "${version}" ]] || pf_fail PF05 "${candidate} does not match release/X.Y.Z-<base12>"
pf_pass PF05 "production candidate ${candidate} (version ${version})"

# PF06 exact-SHA pin
[[ "${commit}" =~ ${RF_RE_COMMIT} ]] || pf_fail PF06 "--commit must be a 40-character lowercase hex commit id"
[[ -n "${cand_tip}" ]] || pf_fail PF06 "candidate branch ${candidate} not found on ${push_remote}"
if [[ "${cand_tip}" != "${commit}" ]]; then
  pf_fail PF06 "candidate branch moved: ${push_remote}/${candidate} is ${cand_tip}, expected ${commit}"
fi
pf_pass PF06 "${candidate} is exactly ${commit}"

# PF07 candidate trailers
trailer() {
  git log -1 --format="%(trailers:key=$1,valueonly)" "${commit}" | sed '/^[[:space:]]*$/d'
}
cfg_project="$(rf_cfg .project)"
for spec in "Release-Project:${cfg_project}" "Release-Version:${version}" "Release-Mode:production" "Release-Base-Branch:${prod_base}"; do
  key="${spec%%:*}"
  want="${spec#*:}"
  got="$(trailer "${key}")"
  if [[ "$(printf '%s\n' "${got}" | wc -l | tr -d ' ')" != "1" || "${got}" != "${want}" ]]; then
    pf_fail PF07 "trailer ${key} is '${got//$'\n'/,}', expected '${want}'"
  fi
done
base_commit="$(trailer Release-Base-Commit)"
[[ "${base_commit}" =~ ${RF_RE_COMMIT} ]] || pf_fail PF07 "trailer Release-Base-Commit is not a 40-character hex commit id"
[[ "${base_commit:0:12}" == "${base12}" ]] || pf_fail PF07 "Release-Base-Commit ${base_commit} does not start with the branch base ${base12}"
pf_pass PF07 "trailers: ${cfg_project} ${version} production from ${prod_base}@${base_commit:0:12}"

# PF08 topology
parents="$(git rev-list --parents -n 1 "${commit}")"
set -- ${parents}
if [[ $# -ne 2 || "$2" != "${base_commit}" ]]; then
  pf_fail PF08 "candidate must have exactly one parent equal to ${base_commit} (parents: ${parents#* })"
fi
pf_pass PF08 "single parent ${base_commit:0:12}"

# PF09 the candidate edits no release tooling; then the config at C rules
changed="$(git diff --name-only "${commit}^" "${commit}")"
[[ -n "${changed}" ]] || pf_fail PF09 "candidate commit changes nothing"
base_cfg_text="$(git show "${commit}^:.release-flow.json" 2>/dev/null || true)"
base_adapter="$(printf '%s' "${base_cfg_text}" | jq -r '.adapter // empty' 2>/dev/null || true)"
lock_paths="$(git show "${commit}^:.release-flow-bundle.json" 2>/dev/null | jq -r '.files[]?.path' 2>/dev/null || true)"
while IFS= read -r f; do
  [[ -n "${f}" ]] || continue
  protected=false
  case "${f}" in
    .github/*|.justfiles/*|scripts/*|.release-flow.json|.release-flow-bundle.json) protected=true ;;
  esac
  [[ -n "${base_adapter}" && "${f}" == "${base_adapter}" ]] && protected=true
  if [[ -n "${lock_paths}" ]] && printf '%s\n' "${lock_paths}" | grep -qxF "${f}"; then
    protected=true
  fi
  if [[ "${protected}" == "true" ]]; then
    pf_fail PF09 "candidate commit edits protected release path ${f}"
  fi
done <<< "${changed}"
c_cfg="${WORK}/candidate-config.json"
git show "${commit}:.release-flow.json" > "${c_cfg}" 2>/dev/null || pf_fail PF09 "missing .release-flow.json at ${commit}"
rf_schema_check config "${c_cfg}" || pf_fail PF09 "invalid .release-flow.json at ${commit}"
rf_config_load_text "$(cat "${c_cfg}")"
c_push_remote="$(rf_cfg .promotion.push_remote)"
[[ -n "${c_push_remote}" ]] || c_push_remote="$(rf_cfg .remote)"
c_main="$(rf_cfg .promotion.main_branch)"
[[ -n "${c_main}" ]] || c_main="main"
if [[ "${c_push_remote}" != "${push_remote}" || "${c_main}" != "${main_branch}" || "$(rf_cfg .production_base)" != "${prod_base}" \
      || "$(rf_cfg .project)" != "${cfg_project}" ]]; then
  pf_fail PF09 "the release configuration at HEAD differs from the one at ${commit}; check out ${prod_base} and retry"
fi
repository="$(rf_cfg .repository)"
[[ -n "${repository}" ]] || pf_fail PF09 ".release-flow.json at ${commit} lacks \"repository\""
mode="$(rf_cfg .promotion.signature_verification)"
[[ -n "${mode}" ]] || mode="github"
signers_path="$(rf_cfg .promotion.allowed_signers)"
workflow="$(rf_cfg .promotion.candidate_workflow)"
[[ -n "${workflow}" ]] || workflow=".github/workflows/candidate.yml"
required_job="$(rf_cfg .promotion.required_job)"
[[ -n "${required_job}" ]] || required_job="Candidate OK"
pf_pass PF09 "changes only $(printf '%s\n' "${changed}" | tr '\n' ' ')(no release tooling); config at ${commit:0:12} is authoritative"

# PF10 version and tags
for t in "${version}" "v${version}"; do
  if [[ -n "$(rf_ls_remote_value "${ls_tags}" "refs/tags/${t}")" ]]; then
    pf_fail PF10 "tag ${t} already exists on ${push_remote}"
  fi
done
highest="$(rf_semver_tags "${ls_tags}" | head -n 1)"
if [[ -n "${highest}" && "$(rf_semver_cmp "${version}" "${highest}")" != "1" ]]; then
  pf_fail PF10 "version ${version} is not greater than the released ${highest} on ${push_remote}"
fi
reuse_tag=""
reuse_run=""
if local_tag="$(git rev-parse -q --verify "refs/tags/${version}" 2>/dev/null)"; then
  if rf_tag_parse "${local_tag}" > "${WORK}/local-record.json" 2>"${WORK}/local-tag.err" && \
     jq -e --arg p "${cfg_project}" --arg r "${repository}" --arg v "${version}" --arg c "${commit}" \
       --arg b "${base_commit}" --arg br "${candidate}" '
       .project == $p and .repository == $r and .version == $v and .candidate_commit == $c
       and .base_commit == $b and .candidate_branch == $br' "${WORK}/local-record.json" >/dev/null; then
    reuse_tag="${local_tag}"
    reuse_run="$(jq -r .run_id "${WORK}/local-record.json")"
  else
    pf_fail PF10 "unpublished local tag ${version} does not belong to this candidate; inspect it, then: git tag -d ${version}"
  fi
fi
if [[ -n "${reuse_tag}" ]]; then
  pf_pass PF10 "${version} > ${highest:-none}; reusing the unpublished local tag ${reuse_tag:0:12} (run ${reuse_run})"
else
  pf_pass PF10 "${version} > ${highest:-none}; ${version} and v${version} are free"
fi

# PF11 production base unchanged since the candidate was prepared
if [[ "${develop_before}" != "${base_commit}" ]]; then
  pf_fail PF11 "stale candidate: ${push_remote}/${prod_base} is ${develop_before}, the candidate was prepared from ${base_commit}; run \`just deploy\` on ${prod_base}"
fi
pf_pass PF11 "${prod_base} is still ${base_commit:0:12}"

# PF12 main fast-forwards to the candidate
if [[ "${main_before}" == "${commit}" ]] || ! git merge-base --is-ancestor "${main_before}" "${commit}"; then
  pf_fail PF12 "${push_remote}/${main_branch} (${main_before:0:12}) cannot fast-forward to ${commit:0:12}"
fi
pf_pass PF12 "${main_branch} ${main_before:0:12} fast-forwards to ${commit:0:12}"

# PF13 the candidate workflow run
if ! run_json="$(rf_gh_candidate_run "${repository}" "${workflow}" "${commit}" "${candidate}" "${reuse_run}" 2>"${WORK}/gh.err")"; then
  pf_fail PF13 "$(cat "${WORK}/gh.err")"
fi
run_id="$(printf '%s' "${run_json}" | jq -r '.id | tostring')"
latest_attempt="$(printf '%s' "${run_json}" | jq -r '.run_attempt // 1')"
pf_pass PF13 "${workflow} run ${run_id} (push on ${candidate}) completed successfully"

# PF14 the required job in the latest attempt
if ! rf_gh_job_ok "${repository}" "${run_id}" "${latest_attempt}" "${required_job}" 2>"${WORK}/gh.err"; then
  pf_fail PF14 "$(cat "${WORK}/gh.err")"
fi
pf_pass PF14 "\"${required_job}\" succeeded in run ${run_id} attempt ${latest_attempt}"

# PF15 the candidate artifact
if ! sel="$(rf_gh_candidate_artifact "${repository}" "${run_id}" "${commit}" 2>"${WORK}/gh.err")"; then
  pf_fail PF15 "$(cat "${WORK}/gh.err")"
fi
artifact_name="${sel% *}"
run_attempt="${sel##* }"
pf_pass PF15 "artifact ${artifact_name}"

# PF16 download and verify the candidate
cand_dir="${WORK}/candidate"
mkdir -p "${cand_dir}"
if ! rf_gh_download_artifact "${repository}" "${run_id}" "${artifact_name}" "${cand_dir}" 2>"${WORK}/gh.err"; then
  pf_fail PF16 "cannot download ${artifact_name}: $(cat "${WORK}/gh.err")"
fi
if ! bash "${RF_SCRIPTS}/verify-candidate.sh" --dir "${cand_dir}" --commit "${commit}" --version "${version}" \
     --mode production --base-commit "${base_commit}" --project "${cfg_project}" --repository "${repository}" \
     --run-id "${run_id}" > "${WORK}/verify.out" 2> "${WORK}/verify.err"; then
  pf_fail PF16 "candidate artifact failed verification: $(tr '\n' ' ' < "${WORK}/verify.err")"
fi
if [[ "$(jq -r .run_attempt "${cand_dir}/manifest.json")" != "${run_attempt}" ]]; then
  pf_fail PF16 "manifest run_attempt differs from the artifact attempt ${run_attempt}"
fi
manifest_sha="$(rf_sha256_file "${cand_dir}/manifest.json")"
sums_sha="$(rf_sha256_file "${cand_dir}/SHA256SUMS")"
pf_pass PF16 "verified $(jq -r '.artifacts | length' "${cand_dir}/manifest.json") artifacts; manifest sha256 ${manifest_sha}"

# PF17 the durable candidate record
storage_uri="$(rf_storage_uri)"
[[ -n "${storage_uri}" ]] || pf_fail PF17 "storage not configured: set storage.uri in .release-flow.json (or RELEASE_FLOW_STORAGE_URI); candidates are only promotable from durable storage"
record_key="candidates/${cfg_project}/${commit}/${run_id}-${run_attempt}.json"
rc=0
rf_storage get-record "${record_key}" "${WORK}/candidate-record.json" --kind candidate-record 2>"${WORK}/st.err" || rc=$?
if (( rc != 0 )); then
  pf_fail PF17 "candidate record ${record_key} unavailable (exit ${rc}): $(tr '\n' ' ' < "${WORK}/st.err")"
fi
if ! jq -e --arg c "${commit}" --arg b "${base_commit}" --arg v "${version}" --arg br "${candidate}" \
     --arg run "${run_id}" --argjson a "${run_attempt}" --arg m "${manifest_sha}" --arg s "${sums_sha}" \
     --arg p "${cfg_project}" --arg r "${repository}" '
     .candidate_commit == $c and .base_commit == $b and .version == $v and .candidate_branch == $br
     and .run_id == $run and .run_attempt == $a and .manifest_sha256 == $m and .sha256sums_sha256 == $s
     and .project == $p and .repository == $r' "${WORK}/candidate-record.json" >/dev/null; then
  pf_fail PF17 "stored candidate record ${record_key} does not match the GitHub artifact (manifest ${manifest_sha} vs $(jq -r .manifest_sha256 "${WORK}/candidate-record.json"))"
fi
pf_pass PF17 "storage record ${record_key} matches manifest ${manifest_sha:0:12}"

# PF18 every stored blob is present and intact
verify_blob() {
  local label="$1" sha="$2" size="${3:-}" rc=0
  if [[ -n "${size}" ]]; then
    rf_storage verify-blob "${sha}" --size "${size}" 2>"${WORK}/st.err" || rc=$?
  else
    rf_storage verify-blob "${sha}" 2>"${WORK}/st.err" || rc=$?
  fi
  case "${rc}" in
    0) ;;
    4) pf_fail PF18 "unrecoverable source artifact ${label}: blob sha256:${sha} is missing from storage; it will not be rebuilt" ;;
    6) pf_fail PF18 "stored ${label} (sha256:${sha}) failed its integrity check" ;;
    *) pf_fail PF18 "cannot read ${label} from storage: $(tr '\n' ' ' < "${WORK}/st.err")" 1 ;;
  esac
}
verify_blob manifest.json "${manifest_sha}"
verify_blob SHA256SUMS "${sums_sha}"
while IFS=$'\t' read -r a_name a_sha a_size; do
  [[ -n "${a_name}" ]] || continue
  verify_blob "${a_name}" "${a_sha}" "${a_size}"
done <<< "$(jq -r '.artifacts[] | [.name, .sha256, (.size | tostring)] | @tsv' "${cand_dir}/manifest.json")"
pf_pass PF18 "manifest, SHA256SUMS and $(jq -r '.artifacts | length' "${cand_dir}/manifest.json") artifact blobs intact in ${storage_uri}"

# PF19 signing readiness
gpg_format="$(git config --get gpg.format || echo openpgp)"
signing_key="$(git config --get user.signingkey || true)"
if [[ "${gpg_format}" == "ssh" ]]; then
  [[ -n "${signing_key}" ]] || pf_fail PF19 "user.signingkey is not set (gpg.format=ssh)"
  pub=""
  case "${signing_key}" in
    key::*) pub="${signing_key#key::}" ;;
    ssh-*|ecdsa-*|sk-*) pub="${signing_key}" ;;
    *)
      key_file="${signing_key/#\~/${HOME:-}}"
      if [[ "${key_file}" == *.pub && -f "${key_file}" ]]; then
        pub="$(cat "${key_file}")"
      elif [[ -f "${key_file}.pub" ]]; then
        pub="$(cat "${key_file}.pub")"
      elif [[ -f "${key_file}" ]]; then
        pub="$(ssh-keygen -y -f "${key_file}" 2>/dev/null || true)"
      fi
      ;;
  esac
  pub="$(printf '%s' "${pub}" | awk '{print $1, $2}')"
  [[ -n "${pub}" && "${pub}" == *" "* ]] || pf_fail PF19 "cannot read the public key of user.signingkey ${signing_key}"
  if [[ "${mode}" == "allowed-signers" ]]; then
    if ! git show "${commit}:${signers_path}" 2>/dev/null | awk -v t="${pub% *}" -v k="${pub#* }" '
        { for (i = 1; i < NF; i++) if ($i == t && $(i + 1) == k) found = 1 } END { exit !found }'; then
      pf_fail PF19 "signing key ${pub% *} ${pub#* } is not in ${signers_path} at ${commit:0:12}"
    fi
  else
    if ! rf_gh_signing_key_registered ssh "${pub}" 2>"${WORK}/gh.err"; then
      pf_fail PF19 "$(cat "${WORK}/gh.err")"
    fi
  fi
  pf_pass PF19 "SSH signing key ${pub% *} ready (${mode})"
elif [[ "${gpg_format}" == "openpgp" ]]; then
  [[ "${mode}" != "allowed-signers" ]] || pf_fail PF19 "allowed-signers verification requires gpg.format=ssh"
  if [[ -z "${signing_key}" ]]; then
    command -v gpg >/dev/null 2>&1 || pf_fail PF19 "no user.signingkey and no gpg for a default key"
    signing_key="$(gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1 == "sec" { print $5; exit }')"
    [[ -n "${signing_key}" ]] || pf_fail PF19 "no signing key: set user.signingkey or create a GPG key"
  fi
  if ! rf_gh_signing_key_registered gpg "${signing_key}" 2>"${WORK}/gh.err"; then
    pf_fail PF19 "$(cat "${WORK}/gh.err")"
  fi
  pf_pass PF19 "GPG signing key ${signing_key} registered on GitHub"
else
  pf_fail PF19 "unsupported gpg.format ${gpg_format} (use ssh or openpgp)"
fi

# PF20 server-side protection, then a dry-run of the branch push
if ! rf_gh_protection_ok "${repository}" "${main_branch}" "${prod_base}" "${required_job}" 2>"${WORK}/gh.err"; then
  pf_fail PF20 "$(cat "${WORK}/gh.err")"
fi
if ! git push --dry-run --atomic --porcelain "${push_remote}" "${commit}:refs/heads/${main_branch}" \
     "${commit}:refs/heads/${prod_base}" > "${WORK}/dry-push.out" 2>&1; then
  pf_fail PF20 "dry-run push rejected: $(tr '\n' ' ' < "${WORK}/dry-push.out")"
fi
pf_pass PF20 "rulesets protect ${main_branch}, ${prod_base} and release tags; dry-run push accepted"

# Expected promotion record (the tag's trailers)
record="${WORK}/record.json"
jq -n --arg p "${cfg_project}" --arg r "${repository}" --arg v "${version}" --arg c "${commit}" \
  --arg b "${base_commit}" --arg br "${candidate}" --arg run "${run_id}" --argjson a "${run_attempt}" \
  --arg m "${manifest_sha}" --arg s "${sums_sha}" --arg st "${storage_uri}" \
  '{schema_version: 1, kind: "promotion-record", project: $p, repository: $r, version: $v,
    candidate_commit: $c, base_commit: $b, candidate_branch: $br, run_id: $run, run_attempt: $a,
    manifest_sha256: $m, sha256sums_sha256: $s, storage: $st}' > "${record}"
rf_schema_check promotion-record "${record}" || rf_die "internal error: invalid promotion record" 1

if [[ "${dry_run}" == "true" ]]; then
  rf_kv preflight passed
  rf_kv project "${cfg_project}"
  rf_kv version "${version}"
  rf_kv tag "${version}"
  rf_kv candidate_branch "${candidate}"
  rf_kv candidate_commit "${commit}"
  rf_kv base_commit "${base_commit}"
  rf_kv run_id "${run_id}"
  rf_kv run_attempt "${run_attempt}"
  rf_kv manifest_sha256 "${manifest_sha}"
  rf_kv main_before "${main_before}"
  echo "Preflight passed; dry run: nothing was tagged or pushed." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Phase 2: Act (T1 tag, T2 re-check, T3 one atomic push)
# ---------------------------------------------------------------------------

# T1 TAG_READY
if [[ -n "${reuse_tag}" ]]; then
  if ! jq -e --slurpfile want "${record}" '. == $want[0]' "${WORK}/local-record.json" >/dev/null; then
    rf_die "[T1] the unpublished local tag ${version} carries different evidence than run ${run_id}/${run_attempt} and manifest ${manifest_sha}; inspect it, then: git tag -d ${version}" 3
  fi
  tag_object="${reuse_tag}"
  tag_how="reused"
else
  rf_tag_message "${record}" > "${WORK}/tag-message"
  if ! rf_tag_create "${version}" "${commit}" "${WORK}/tag-message" 2>"${WORK}/tag.err"; then
    rf_die "[T1] cannot create the signed tag ${version}: $(tr '\n' ' ' < "${WORK}/tag.err")" 1
  fi
  tag_object="$(git rev-parse --verify "refs/tags/${version}")"
  tag_how="created"
fi
if ! git cat-file tag "${tag_object}" | grep -qE '^-----BEGIN (SSH|PGP) SIGNATURE-----$'; then
  rf_die "[T1] local tag ${version} is not signed; delete it (git tag -d ${version}) and fix signing" 3
fi
if [[ "${mode}" == "allowed-signers" ]] && \
   ! rf_tag_verify_signature "${tag_object}" "${mode}" "${repository}" "${commit}" "${signers_path}"; then
  rf_die "[T1] local tag ${version} does not verify against ${signers_path}; delete it (git tag -d ${version}) and fix signing" 3
fi
echo "[T1] TAG_READY ${version} ${tag_object} (${tag_how})" >&2

# T2 RECHECK: the remote still equals the preflight snapshot
if ! recheck="$(git ls-remote "${push_remote}" "refs/heads/${main_branch}" "refs/heads/${prod_base}" "refs/tags/${version}")"; then
  rf_die "[T2] cannot re-read ${push_remote}; nothing was pushed (the local tag ${version} is kept and reusable)" 1
fi
now_main="$(rf_ls_remote_value "${recheck}" "refs/heads/${main_branch}")"
now_dev="$(rf_ls_remote_value "${recheck}" "refs/heads/${prod_base}")"
now_tag="$(rf_ls_remote_value "${recheck}" "refs/tags/${version}")"
if [[ "${now_main}" != "${main_before}" || "${now_dev}" != "${develop_before}" || "${now_tag:-absent}" != "${tag_before}" ]]; then
  rf_die "[T2] remote moved during promotion; nothing was pushed (the local tag ${version} is kept). Rerun \`just release-promote\`." 3
fi
echo "[T2] RECHECK remote unchanged since preflight" >&2

# T3 PUSH: exactly one atomic push of three refs
set +e
push_out="$(git push --atomic --porcelain "${push_remote}" "${commit}:refs/heads/${main_branch}" \
  "${commit}:refs/heads/${prod_base}" "refs/tags/${version}:refs/tags/${version}" 2>&1)"
push_rc=$?
set -e
printf '%s\n' "${push_out}" | sed 's/^/[T3] /' >&2
push_desc="ambiguous"
if printf '%s\n' "${push_out}" | grep -q '^Done$'; then
  if ! printf '%s\n' "${push_out}" | grep -E '^[ +*=!-]	' | grep -qvE '^!	'; then
    push_desc="rejected"
  fi
fi
echo "[T3] PUSH exit ${push_rc}" >&2

# ---------------------------------------------------------------------------
# Phase 3: Reconcile (T4) and verify (T5); the verdict comes from the remote
# ---------------------------------------------------------------------------

attempts="${RELEASE_FLOW_RECONCILE_ATTEMPTS:-5}"
delay="${RELEASE_FLOW_RECONCILE_DELAY:-2}"
[[ "${attempts}" =~ ^[1-9][0-9]*$ ]] || attempts=5
[[ "${delay}" =~ ^[0-9]+$ ]] || delay=2
obs=""
observed=false
i=0
while (( i < attempts )); do
  i=$(( i + 1 ))
  if obs="$(git ls-remote "${push_remote}" "refs/heads/${main_branch}" "refs/heads/${prod_base}" \
        "refs/tags/${version}" "refs/tags/${version}^{}" 2>/dev/null)"; then
    observed=true
    break
  fi
  if (( i < attempts )); then
    sleep "${delay}"
    delay=$(( delay * 2 ))
  fi
done
if [[ "${observed}" != "true" ]]; then
  rf_die "[T4] UNKNOWN: push outcome unknown (${push_remote} unreachable after ${attempts} attempts). Rerun \`just release-promote ${candidate} ${commit}\`; it reconciles before pushing." 11
fi
r_main="$(rf_ls_remote_value "${obs}" "refs/heads/${main_branch}")"
r_dev="$(rf_ls_remote_value "${obs}" "refs/heads/${prod_base}")"
r_tag="$(rf_ls_remote_value "${obs}" "refs/tags/${version}")"
r_peel="$(rf_ls_remote_value "${obs}" "refs/tags/${version}^{}")"
[[ -n "${r_peel}" ]] || r_peel="${r_tag}"

if [[ -z "${r_tag}" ]]; then
  if [[ "${r_main}" == "${main_before}" && "${r_dev}" == "${develop_before}" ]]; then
    rf_die "[T4] NOT_PROMOTED: push ${push_desc}; ${push_remote} is unchanged. The signed local tag ${version} (${tag_object}) is kept; rerun \`just release-promote ${candidate} ${commit}\` to reuse it." 10
  fi
  rf_die "[T4] STALE: push ${push_desc} and ${push_remote} moved (${main_branch} ${r_main:0:12}, ${prod_base} ${r_dev:0:12}); this candidate is stale. The local tag ${version} was not published; delete it (git tag -d ${version}) and prepare a new candidate." 3
fi
if [[ "${r_peel}" != "${commit}" ]]; then
  rf_die "[T4] CONFLICT: ${push_remote} tag ${version} points to ${r_peel}, not ${commit}" 12
fi
if ! rf_git_fetch "${push_remote}" \
     "+refs/heads/${main_branch}:refs/release-flow/remote/main" \
     "+refs/heads/${prod_base}:refs/release-flow/remote/develop" \
     "+refs/tags/${version}:refs/release-flow/remote/tag"; then
  rf_die "[T4] UNKNOWN: tag ${version} is on ${push_remote} but its objects cannot be fetched; rerun to reconcile" 11
fi
contained=false
if git merge-base --is-ancestor "${commit}" refs/release-flow/remote/main && \
   git merge-base --is-ancestor "${commit}" refs/release-flow/remote/develop; then
  contained=true
fi
promoted_by_other=false
if [[ "${r_tag}" != "${tag_object}" ]]; then
  if ! rf_tag_parse "${r_tag}" > "${WORK}/other-record.json" 2>"${WORK}/other.err" || \
     ! jq -e --slurpfile want "${record}" '.candidate_commit == $want[0].candidate_commit and .manifest_sha256 == $want[0].manifest_sha256 and .version == $want[0].version' \
       "${WORK}/other-record.json" >/dev/null; then
    rf_die "[T4] CONFLICT: ${push_remote} tag ${version} (${r_tag}) binds a different identity than manifest ${manifest_sha}" 12
  fi
  if [[ "${mode}" == "allowed-signers" ]] && \
     ! rf_tag_verify_signature "${r_tag}" "${mode}" "${repository}" "${commit}" "${signers_path}"; then
    rf_die "[T4] CONFLICT: ${push_remote} tag ${version} (${r_tag}) is not signed by an allowed signer" 12
  fi
  promoted_by_other=true
fi
if [[ "${contained}" != "true" ]]; then
  rf_die "[T4] INCONSISTENT: tag ${version} -> ${commit} exists on ${push_remote} but ${main_branch} (${r_main:0:12}) or ${prod_base} (${r_dev:0:12}) does not contain it. Manual repair required; nothing is fixed automatically." 13
fi
reconciled=false
if [[ "${promoted_by_other}" == "true" ]]; then
  echo "[T4] PROMOTED_BY_OTHER: ${version} was promoted concurrently with tag object ${r_tag} (same commit and manifest)." >&2
  echo "     Your local tag ${tag_object} was not published; align it with: git tag -d ${version} && git fetch ${push_remote} tag ${version}" >&2
  final_record="${WORK}/other-record.json"
else
  if (( push_rc != 0 )); then
    reconciled=true
    echo "[T4] PROMOTED (reconciled): the push reported exit ${push_rc} but ${push_remote} holds the tag and both branches" >&2
  else
    echo "[T4] PROMOTED" >&2
  fi
  final_record="${record}"
fi

# T5 VERIFY (github mode): publishers refuse an unverified tag
if [[ "${mode}" == "github" ]] && ! rf_gh_tag_verified "${repository}" "${r_tag}"; then
  emit_result "${final_record}" "${r_tag}" PROMOTED false "${promoted_by_other}" "${reconciled}"
  rf_die "[T5] refs are promoted, but GitHub reports tag object ${r_tag} as unverified; publishers will refuse it. Register the signing key on the tagger's GitHub account (SSH signing key or GPG key)." 14
fi

emit_result "${final_record}" "${r_tag}" PROMOTED false "${promoted_by_other}" "${reconciled}"
{
  echo "Promoted ${cfg_project} ${version}"
  echo "  tag:       ${version} -> ${commit:0:12} (tag object ${r_tag:0:12})"
  echo "  branches:  ${main_branch} ${main_before:0:12} -> ${commit:0:12}, ${prod_base} ${develop_before:0:12} -> ${commit:0:12}"
  echo "  manifest:  ${manifest_sha}"
  echo "  The tag push starts release.yml; follow it with: just release-status ${version}"
} >&2
