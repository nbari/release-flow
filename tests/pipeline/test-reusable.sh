#!/usr/bin/env bash
# Pinned reusable workflow_call: pin script, workflow contract, caller templates.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pin="${ROOT}/scripts/pipeline-pin.sh"
orig_dir="$(pwd)"

new_pipe() {
  local dir="${TF_TMP}/pipe-$1"
  git init --quiet "${dir}"
  git -C "${dir}" commit --quiet --allow-empty -m "pipeline"
  printf '%s' "${dir}"
}

write_cfg() {
  local dir="$1" repo="${2:-}" sha="${3:-}"
  mkdir -p "${dir}"
  if [[ -n "${repo}" ]]; then
    jq -n --arg r "${repo}" --arg s "${sha}" '{pipeline: {repository: $r, sha: $s}}' > "${dir}/.release-flow.json"
  else
    printf '{}\n' > "${dir}/.release-flow.json"
  fi
}

run_pin() {
  local pipe="$1" dest="$2" cfg="$3" wf_repo="$4" wf_ref="$5" wf_sha="$6" repo="$7" commit="$8"
  t_run bash "${pin}" --project-dir "${cfg}" --checkout "${pipe}" --dest "${dest}" \
    --workflow-repository "${wf_repo}" --workflow-ref "${wf_ref}" --workflow-sha "${wf_sha}" \
    --repository "${repo}" --commit "${commit}"
}

# ---------------------------------------------------------------------------

t_case "RW1: Pin script"
pipe="$(new_pipe local-ok)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-local-ok"
dest="${TF_TMP}/dest-local-ok"
write_cfg "${cfg}"
run_pin "${pipe}" "${dest}" "${cfg}" "acme/app" "acme/app/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "${sha}"
assert_rc 0 "RW1 local: exit 0"
assert_contains "${T_OUT}" "pipeline_mode=local" "RW1 local: mode"
assert_contains "${T_OUT}" "pipeline_repository=acme/app" "RW1 local: repository"
assert_contains "${T_OUT}" "pipeline_sha=${sha}" "RW1 local: sha"
assert_eq "${sha}" "$(git -C "${dest}" rev-parse HEAD)" "RW1 local: dest HEAD"
assert_eq "absent" "$([[ -e "${pipe}" ]] && echo present || echo absent)" "RW1 local: source moved"

pipe="$(new_pipe call-ok)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-call-ok"
dest="${TF_TMP}/dest-call-ok"
write_cfg "${cfg}" "nbari/release-flow" "${sha}"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
assert_rc 0 "RW1 call: exit 0"
assert_contains "${T_OUT}" "pipeline_mode=call" "RW1 call: mode"
assert_contains "${T_OUT}" "pipeline_repository=nbari/release-flow" "RW1 call: repository"
assert_contains "${T_OUT}" "pipeline_sha=${sha}" "RW1 call: sha"
assert_eq "${sha}" "$(git -C "${dest}" rev-parse HEAD)" "RW1 call: dest HEAD"

pipe="$(new_pipe tag-ref)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-tag-ref"
dest="${TF_TMP}/dest-tag-ref"
write_cfg "${cfg}" "nbari/release-flow" "${sha}"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@refs/tags/v1" "${sha}" "acme/app" "${sha}"
assert_rc 3 "RW1 tag ref: exit 3"
assert_contains "${T_ERR}" "full commit SHA" "RW1 tag ref: explains"
assert_eq "absent" "$([[ -e "${dest}" ]] && echo present || echo absent)" "RW1 tag ref: dest absent"

pipe="$(new_pipe branch-ref)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-branch-ref"
dest="${TF_TMP}/dest-branch-ref"
write_cfg "${cfg}" "nbari/release-flow" "${sha}"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@refs/heads/main" "${sha}" "acme/app" "${sha}"
assert_rc 3 "RW1 branch ref: exit 3"
assert_eq "absent" "$([[ -e "${dest}" ]] && echo present || echo absent)" "RW1 branch ref: dest absent"

pipe="$(new_pipe sha-diff)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
other="0123456789abcdef0123456789abcdef01234567"
cfg="${TF_TMP}/cfg-sha-diff"
dest="${TF_TMP}/dest-sha-diff"
write_cfg "${cfg}" "nbari/release-flow" "${other}"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "${sha}"
assert_rc 3 "RW1 config sha differs: exit 3"
assert_contains "${T_ERR}" "does not match" "RW1 config sha differs: explains"

pipe="$(new_pipe repo-diff)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-repo-diff"
dest="${TF_TMP}/dest-repo-diff"
write_cfg "${cfg}" "other/release-flow" "${sha}"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "${sha}"
assert_rc 3 "RW1 config repo differs: exit 3"
assert_contains "${T_ERR}" "does not match" "RW1 config repo differs: explains"

pipe="$(new_pipe no-pipe)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-no-pipe"
dest="${TF_TMP}/dest-no-pipe"
write_cfg "${cfg}"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "${sha}"
assert_rc 3 "RW1 no pipeline: exit 3"
assert_contains "${T_ERR}" "declares no pipeline" "RW1 no pipeline: explains"
assert_eq "absent" "$([[ -e "${dest}" ]] && echo present || echo absent)" "RW1 no pipeline: dest absent"

pipe="$(new_pipe head-diff)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-head-diff"
dest="${TF_TMP}/dest-head-diff"
write_cfg "${cfg}" "nbari/release-flow" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
run_pin "${pipe}" "${dest}" "${cfg}" "nbari/release-flow" \
  "nbari/release-flow/.github/workflows/candidate.yml@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "acme/app" "${sha}"
assert_rc 3 "RW1 HEAD differs: exit 3"

pipe="$(new_pipe bad-sha)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-bad-sha"
dest="${TF_TMP}/dest-bad-sha"
write_cfg "${cfg}"
run_pin "${pipe}" "${dest}" "${cfg}" "acme/app" "acme/app/.github/workflows/candidate.yml@ABCDEF" \
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789ABCD" "acme/app" "${sha}"
assert_rc 3 "RW1 uppercase sha: exit 3"
run_pin "${pipe}" "${dest}" "${cfg}" "acme/app" "acme/app/.github/workflows/candidate.yml@0123456789ab" \
  "0123456789ab" "acme/app" "${sha}"
assert_rc 3 "RW1 short sha: exit 3"
assert_eq "absent" "$([[ -e "${dest}" ]] && echo present || echo absent)" "RW1 bad sha: dest absent"

pipe="$(new_pipe local-decl)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-local-decl"
dest="${TF_TMP}/dest-local-decl"
write_cfg "${cfg}" "acme/app" "${sha}"
run_pin "${pipe}" "${dest}" "${cfg}" "acme/app" "acme/app/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "${sha}"
assert_rc 3 "RW1 local with pipeline: exit 3"
assert_contains "${T_ERR}" "own workflow" "RW1 local with pipeline: explains"

pipe="$(new_pipe empty-ok)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-empty-ok"
dest="${TF_TMP}/dest-empty-ok"
write_cfg "${cfg}"
run_pin "${pipe}" "${dest}" "${cfg}" "" "" "" "acme/app" "${sha}"
assert_rc 3 "RW1 empty context: rejected without mutable fallback"
assert_contains "${T_ERR}" "no fallback" "RW1 empty context: explains"
assert_eq absent "$([[ -e "${dest}" ]] && echo present || echo absent)" "RW1 empty context: dest absent"

pipe="$(new_pipe empty-decl)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-empty-decl"
dest="${TF_TMP}/dest-empty-decl"
write_cfg "${cfg}" "nbari/release-flow" "${sha}"
run_pin "${pipe}" "${dest}" "${cfg}" "" "" "" "acme/app" "${sha}"
assert_rc 3 "RW1 empty context with pipeline: exit 3"
assert_contains "${T_ERR}" "job.workflow_" "RW1 empty context with pipeline: explains"

pipe="$(new_pipe empty-head)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-empty-head"
dest="${TF_TMP}/dest-empty-head"
write_cfg "${cfg}"
run_pin "${pipe}" "${dest}" "${cfg}" "" "" "" "acme/app" "cccccccccccccccccccccccccccccccccccccccc"
assert_rc 3 "RW1 empty context HEAD mismatch: exit 3"

pipe="$(new_pipe dest-exists)"
sha="$(git -C "${pipe}" rev-parse HEAD)"
cfg="${TF_TMP}/cfg-dest-exists"
dest="${TF_TMP}/dest-exists"
write_cfg "${cfg}"
mkdir -p "${dest}"
run_pin "${pipe}" "${dest}" "${cfg}" "acme/app" "acme/app/.github/workflows/candidate.yml@${sha}" "${sha}" "acme/app" "${sha}"
assert_rc 1 "RW1 dest exists: exit 1"
assert_eq "${sha}" "$(git -C "${pipe}" rev-parse HEAD)" "RW1 dest exists: source not moved"

t_run bash "${pin}" --dest "${TF_TMP}/unused" --workflow-repository "" --workflow-ref "" --workflow-sha "" \
  --repository "acme/app" --commit "${sha}"
assert_rc 2 "RW1 missing checkout: exit 2"

# ---------------------------------------------------------------------------

job_pin_count() {
  local file="$1" in_jobs=0 job="" body="" count=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" == "jobs:" ]]; then
      in_jobs=1
      continue
    fi
    if [[ "${in_jobs}" -eq 1 && "${line}" =~ ^[^[:space:]#] ]]; then
      in_jobs=0
    fi
    if [[ "${in_jobs}" -eq 1 && "${line}" =~ ^[[:space:]][[:space:]][A-Za-z0-9_-]+:$ ]]; then
      if [[ -n "${job}" && "${body}" == *RF_PIPELINE* ]]; then
        count=$((count + 1))
        if [[ "${body}" != *'ref: ${{ job.workflow_sha }}'* \
              || "${body}" != *'repository: ${{ job.workflow_repository }}'* \
              || "${body}" != *'Require immutable runtime identity before checkout'* \
              || "${body}" != *pipeline-pin.sh* ]]; then
          printf 'incomplete:%s\n' "${job}"
          return 0
        fi
      fi
      job="${line}"
      body=""
      continue
    fi
    if [[ -n "${job}" ]]; then
      body+="${line}"$'\n'
    fi
  done < "${file}"
  if [[ -n "${job}" && "${body}" == *RF_PIPELINE* ]]; then
    count=$((count + 1))
    if [[ "${body}" != *'ref: ${{ job.workflow_sha }}'* \
          || "${body}" != *'repository: ${{ job.workflow_repository }}'* \
          || "${body}" != *'Require immutable runtime identity before checkout'* \
          || "${body}" != *pipeline-pin.sh* ]]; then
      printf 'incomplete:%s\n' "${job}"
      return 0
    fi
  fi
  printf '%s\n' "${count}"
}

declared_secrets() {
  awk '
    /^  workflow_call:$/ { call=1; next }
    call && /^  [A-Za-z0-9_-]+:$/ { call=0 }
    call && /^    secrets:$/ { sec=1; next }
    sec && /^    [A-Za-z0-9_-]+:$/ { sec=0 }
    sec && /^      [A-Z0-9_]+:$/ { gsub(/:/, "", $1); print $1 }
  ' "$1" | sort -u
}

t_case "RW2: Workflow contract"
for wf in candidate release; do
  file="${ROOT}/.github/workflows/${wf}.yml"
  assert_eq "1" "$(grep -c '^  workflow_call:$' "${file}")" "RW2 ${wf}: one workflow_call"
  assert_eq "1" "$(grep -c '^  push:$' "${file}")" "RW2 ${wf}: keeps push"
  assert_eq "" "$(grep -nE '(bash|\./)[[:space:]]*"?scripts/' "${file}" || true)" "RW2 ${wf}: no vendored script path"
  assert_eq "" "$(grep -nE 'github\.workflow_ref|github\.workflow_sha|ref: main|@main' "${file}" || true)" "RW2 ${wf}: no caller context or main pin"
  shell_block="$(awk '
    $0 == "defaults:" { d=1; next }
    d && $0 == "  run:" { r=1; next }
    d && r && $0 == "    shell: bash" { print "defaults:"; print "  run:"; print "    shell: bash"; exit }
    d { exit }
  ' "${file}")"
  assert_eq $'defaults:\n  run:\n    shell: bash' "${shell_block}" "RW2 ${wf}: defaults.run.shell is bash so pipeline-pin.sh | tee cannot hide a pin failure"
done
assert_eq "" "$(grep -n '^  workflow_dispatch:$' "${ROOT}/.github/workflows/candidate.yml" || true)" "RW2 candidate: no dispatch"
assert_eq "1" "$(grep -c '^  workflow_dispatch:$' "${ROOT}/.github/workflows/release.yml")" "RW2 release: keeps dispatch"
assert_eq "4" "$(job_pin_count "${ROOT}/.github/workflows/candidate.yml")" "RW2 candidate: four pinned jobs"
assert_eq "6" "$(job_pin_count "${ROOT}/.github/workflows/release.yml")" "RW2 release: plan and five pinned jobs"
assert_eq "" "$(grep -nE 'ADAPTER|upload-artifact|download-artifact|cargo build|candidate-manifest' "${ROOT}/.github/workflows/release.yml" || true)" "RW2 release: no build or artifact steps"
inputs="$(awk '
  /^  workflow_call:$/ { call=1; next }
  call && /^  [A-Za-z0-9_-]+:$/ { call=0 }
  call && /^    inputs:$/ { ins=1; next }
  ins && /^    [A-Za-z0-9_-]+:$/ { ins=0 }
  ins && /^      [A-Za-z0-9_-]+:$/ { gsub(/:/, "", $1); print $1 }
' "${ROOT}/.github/workflows/release.yml" | sort)"
assert_eq "channel
version" "${inputs}" "RW2 release: workflow_call inputs are channel and version"
release="${ROOT}/.github/workflows/release.yml"
assert_eq '  VERSION: ${{ inputs.version || github.ref_name }}' \
  "$(grep -Fx '  VERSION: ${{ inputs.version || github.ref_name }}' "${release}")" \
  "RW2 release: VERSION prefers a non-empty inputs.version"
assert_eq "" "$(grep -n "github.event_name == 'push'" "${release}" || true)" \
  "RW2 release: caller push is not a run-all-channels gate"
for channel in github-release oci crates-io docs helm; do
  assert_eq "    if: needs.plan.outputs.${channel} == 'true'" \
    "$(grep -Fx "    if: needs.plan.outputs.${channel} == 'true'" "${release}")" \
    "RW2 release: ${channel} runs only when selected and configured"
  assert_eq "      group: publish-${channel}-\${{ inputs.version || github.ref_name }}" \
    "$(grep -Fx "      group: publish-${channel}-\${{ inputs.version || github.ref_name }}" "${release}")" \
    "RW2 release: ${channel} concurrency uses the resolved version"
done
for wf in candidate release; do
  file="${ROOT}/.github/workflows/${wf}.yml"
  missing=""
  while IFS= read -r name; do
    [[ -n "${name}" && "${name}" != "GITHUB_TOKEN" ]] || continue
    if ! declared_secrets "${file}" | grep -qx "${name}"; then
      missing+="${name} "
    fi
  done < <(grep -oE 'secrets\.[A-Z][A-Z0-9_]*' "${file}" | sed 's/^secrets\.//' | sort -u)
  assert_eq "" "${missing}" "RW2 ${wf}: every secret is declared on workflow_call"
done

# ---------------------------------------------------------------------------

t_case "RW4: Bootstrap rejects missing identity before loading runtime code"
mkdir -p "${TF_TMP}/bootstrap"
cd "${TF_TMP}/bootstrap"
for wf in candidate release; do
  bootstrap="${TF_TMP}/bootstrap-${wf}.sh"
  awk '
    /- name: Require immutable runtime identity before checkout/ { found=1 }
    found && /^        run: \|$/ { body=1; next }
    body && /^          / { print substr($0, 11); next }
    body { exit }
  ' "${ROOT}/.github/workflows/${wf}.yml" > "${bootstrap}"
  assert_contains "$(cat "${bootstrap}")" 'Missing immutable workflow identity' "RW4 ${wf}: real bootstrap extracted"
  ref="nbari/release-flow/.github/workflows/${wf}.yml@${sha}"
  t_run env RF_WORKFLOW_REPOSITORY=nbari/release-flow RF_WORKFLOW_REF="${ref}" RF_WORKFLOW_SHA="${sha}" bash -euo pipefail "${bootstrap}"
  assert_rc 0 "RW4 ${wf}: full identity accepted"
  t_run env RF_WORKFLOW_REPOSITORY= RF_WORKFLOW_REF= RF_WORKFLOW_SHA= bash -euo pipefail "${bootstrap}"
  assert_rc nonzero "RW4 ${wf}: empty contexts rejected before checkout"
  t_run env RF_WORKFLOW_REPOSITORY=nbari/release-flow RF_WORKFLOW_REF="${ref}" RF_WORKFLOW_SHA=main bash -euo pipefail "${bootstrap}"
  assert_rc nonzero "RW4 ${wf}: mutable revision rejected before checkout"
  t_run env RF_WORKFLOW_REPOSITORY=other/repo RF_WORKFLOW_REF="${ref}" RF_WORKFLOW_SHA="${sha}" bash -euo pipefail "${bootstrap}"
  assert_rc nonzero "RW4 ${wf}: repository confusion rejected before checkout"
  ln -s "${TF_TMP}" .release-flow-pipeline
  t_run env RF_WORKFLOW_REPOSITORY=nbari/release-flow RF_WORKFLOW_REF="${ref}" RF_WORKFLOW_SHA="${sha}" bash -euo pipefail "${bootstrap}"
  assert_rc nonzero "RW4 ${wf}: preexisting runtime symlink rejected"
  rm .release-flow-pipeline
done
cd "${orig_dir}"

# ---------------------------------------------------------------------------

caller_perm_ok() {
  local called="$1" caller="$2" perm level
  while read -r perm level; do
    [[ -n "${perm}" ]] || continue
    if [[ "${level}" == "write" ]]; then
      grep -qE "^[[:space:]]*${perm}: write$" "${caller}" || return 1
    else
      grep -qE "^[[:space:]]*${perm}: (read|write)$" "${caller}" || return 1
    fi
  done < <(grep -E '^[[:space:]]*[A-Za-z0-9_-]+: (read|write)$' "${called}" | sed -E 's/^[[:space:]]*//; s/: / /')
}

adoption_block() {
  awk -v marker="$1" '
    $0 == marker { hit=1; next }
    hit == 1 && $0 == "```yaml" { hit=2; next }
    hit == 2 && $0 == "```" { exit }
    hit == 2 { print }
  ' "${ROOT}/docs/ADOPTION.md"
}

round_trip() {
  local caller="$1" subst="$2" expect="$3" label="$4" sha ref wf_repo pipe cfg dest
  sha="$(git -C "${ROOT}" rev-parse HEAD)"
  ref="$(sed -n 's/^[[:space:]]*uses: //p' "${caller}")"
  ref="${ref//__RELEASE_FLOW_SHA__/${subst}}"
  wf_repo="${ref%%/.github/workflows/*}"
  pipe="$(new_pipe "rt-${label}")"
  git -C "${pipe}" fetch --quiet "${ROOT}" "${sha}"
  git -C "${pipe}" checkout --quiet --detach "${sha}"
  cfg="${TF_TMP}/cfg-rt-${label}"
  dest="${TF_TMP}/dest-rt-${label}"
  write_cfg "${cfg}" "${wf_repo}" "${sha}"
  run_pin "${pipe}" "${dest}" "${cfg}" "${wf_repo}" "${ref}" "${sha}" "acme/adopter" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  assert_rc "${expect}" "RW3 ${label}: exit ${expect}"
}

t_case "RW3: Caller contract"
for base in candidate release; do
  caller="${ROOT}/docs/callers/${base}.yml"
  assert_eq "1" "$(grep -c "^    uses: nbari/release-flow/.github/workflows/${base}.yml@__RELEASE_FLOW_SHA__$" "${caller}")" "RW3 ${base}: pinned uses"
  assert_eq "1" "$(grep -c 'uses:' "${caller}")" "RW3 ${base}: one uses"
  assert_eq "1" "$(grep -c "^  ${base}:$" "${caller}")" "RW3 ${base}: job id"
  assert_eq "" "$(grep -n 'secrets: inherit' "${caller}" || true)" "RW3 ${base}: explicit secrets only"
  assert_eq "" "$(grep -n 'concurrency:' "${caller}" || true)" "RW3 ${base}: no concurrency"
done
assert_eq "1" "$(grep -c "^    branches: \\['release/\\*\\*'\\]$" "${ROOT}/docs/callers/candidate.yml")" "RW3 candidate: release/** push"
assert_eq "" "$(grep -nE 'workflow_dispatch:|workflow_call:|tags:' "${ROOT}/docs/callers/candidate.yml" || true)" "RW3 candidate: push only"
assert_eq "    tags: ['[0-9]+.[0-9]+.[0-9]+']" "$(grep -Fx "    tags: ['[0-9]+.[0-9]+.[0-9]+']" "${ROOT}/docs/callers/release.yml")" "RW3 release: tag push"
assert_eq "1" "$(grep -c '^  workflow_dispatch:$' "${ROOT}/docs/callers/release.yml")" "RW3 release: dispatch"
assert_eq "" "$(grep -n '^  workflow_call:$' "${ROOT}/docs/callers/release.yml" || true)" "RW3 release caller: not itself callable"
called_opts="$(grep -x '        options: \[github-release, oci, crates-io, docs, helm\]' "${ROOT}/.github/workflows/release.yml")"
caller_opts="$(grep -x '        options: \[github-release, oci, crates-io, docs, helm\]' "${ROOT}/docs/callers/release.yml")"
assert_eq "${called_opts}" "${caller_opts}" "RW3 release: options line matches"
assert_eq "channel
version" "$(awk '
  /^    with:$/ { w=1; next }
  w && /^    [A-Za-z]/ { w=0 }
  w && /^      [A-Za-z0-9_-]+:/ { gsub(/:.*/, "", $1); print $1 }
' "${ROOT}/docs/callers/release.yml" | sort)" "RW3 release: with keys"
if caller_perm_ok "${ROOT}/.github/workflows/candidate.yml" "${ROOT}/docs/callers/candidate.yml"; then
  T_PASSED=$((T_PASSED + 1))
else
  printf '    FAIL: RW3 candidate permissions\n' >&2
  T_FAILED=$((T_FAILED + 1))
fi
if caller_perm_ok "${ROOT}/.github/workflows/release.yml" "${ROOT}/docs/callers/release.yml"; then
  T_PASSED=$((T_PASSED + 1))
else
  printf '    FAIL: RW3 release permissions\n' >&2
  T_FAILED=$((T_FAILED + 1))
fi
head_sha="$(git -C "${ROOT}" rev-parse HEAD)"
round_trip "${ROOT}/docs/callers/candidate.yml" "${head_sha}" 0 "candidate-sha"
round_trip "${ROOT}/docs/callers/release.yml" "${head_sha}" 0 "release-sha"
round_trip "${ROOT}/docs/callers/candidate.yml" "v1" 3 "candidate-v1"
round_trip "${ROOT}/docs/callers/release.yml" "v1" 3 "release-v1"
for base in candidate release; do
  marker="<!-- release-flow caller: docs/callers/${base}.yml -->"
  assert_eq "1" "$(grep -c "^${marker}$" "${ROOT}/docs/ADOPTION.md")" "RW3 ${base}: adoption marker"
  next="$(awk -v marker="${marker}" '$0 == marker { getline; print; exit }' "${ROOT}/docs/ADOPTION.md")"
  assert_eq '```yaml' "${next}" "RW3 ${base}: fence follows the marker"
  adoption_block "${marker}" > "${TF_TMP}/adoption-${base}.yml"
  if cmp -s "${ROOT}/docs/callers/${base}.yml" "${TF_TMP}/adoption-${base}.yml"; then
    T_PASSED=$((T_PASSED + 1))
  else
    printf '    FAIL: RW3 %s adoption block is not byte-identical\n' "${base}" >&2
    T_FAILED=$((T_FAILED + 1))
  fi
done

cd "${orig_dir}"
t_finish
