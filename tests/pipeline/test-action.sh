#!/usr/bin/env bash
# Test the real Action entrypoint with separate trusted and consumer roots.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
project="${TF_TMP}/consumer with spaces"
mkdir -p "${project}"
cp -R "${ROOT}/examples/shell/." "${project}/"
chmod +x "${project}/tools/adapter.sh"
export GITHUB_WORKSPACE="${project}"
export GITHUB_OUTPUT="${TF_TMP}/outputs"
export RF_ACTION_REF=1234567890123456789012345678901234567890
action="${ROOT}/scripts/action.sh"

t_case 'Root Action metadata and implementation stay aligned'
metadata="${ROOT}/action.yml"
for field in name description branding inputs outputs runs; do
  assert_eq 1 "$(grep -c "^${field}:" "${metadata}")" "metadata ${field}"
done
assert_eq '  using: composite' "$(grep '^  using:' "${metadata}")" 'composite runtime'
assert_eq '    default: validate' "$(grep '^    default: validate$' "${metadata}")" 'safe operation default'
for output in project project-directory adapter runtime-revision validation-json; do
  assert_contains "$(cat "${metadata}")" "steps.validate.outputs.${output}" "declared output ${output}"
  assert_contains "$(cat "${action}")" "rf_kv ${output}" "implemented output ${output}"
done

t_case 'Action validates the consumer without executing its code'
printf '\ntouch SHOULD_NOT_EXIST\n' >> "${project}/tools/adapter.sh"
before="$(find "${project}" -type f -exec sha256sum {} \; | sort)"
t_run bash "${action}"
assert_rc 0 'valid config succeeds'
assert_contains "${T_OUT}" 'project=hello' 'uses consumer config'
assert_contains "${T_OUT}" 'adapter_executed":false' 'reports static validation'
assert_contains "${T_OUT}" 'runtime-revision=1234567890123456789012345678901234567890' 'reports runtime SHA'
assert_eq "${before}" "$(find "${project}" -type f -exec sha256sum {} \; | sort)" 'consumer unchanged'
assert_eq absent "$([[ -e SHOULD_NOT_EXIST || -e "${project}/SHOULD_NOT_EXIST" ]] && echo present || echo absent)" 'adapter never ran'
assert_eq "${T_OUT}" "$(cat "${GITHUB_OUTPUT}")" 'machine outputs match stdout'

t_case 'An adapter shebang cannot select validation code'
mkdir -p "${TF_TMP}/interpreter"
printf '#!/bin/sh\ntouch "%s"\n' "${TF_TMP}/INTERPRETER_EXECUTED" > "${TF_TMP}/interpreter/bash"
chmod +x "${TF_TMP}/interpreter/bash"
cp "${project}/tools/adapter.sh" "${TF_TMP}/original-adapter"
{ printf '#!%s\n' "${TF_TMP}/interpreter/bash"; tail -n +2 "${TF_TMP}/original-adapter"; } > "${project}/tools/adapter.sh"
t_run bash "${action}"
assert_rc 0 'absolute interpreter inspected as data'
assert_eq absent "$([[ -e "${TF_TMP}/INTERPRETER_EXECUTED" ]] && echo present || echo absent)" 'consumer interpreter never executed'
cp "${TF_TMP}/original-adapter" "${project}/tools/adapter.sh"

t_case 'Unsafe inputs fail before execution'
RF_INPUT_OPERATION=publish t_run bash "${action}"
assert_rc 2 'unknown operation rejected'
for path in '../escape' '/tmp' 'tools/../tools/adapter.sh' 'tools//adapter.sh' $'tools/adapter.sh\nx=y'; do
  jq --arg p "${path}" '.adapter=$p' "${ROOT}/examples/shell/.release-flow.json" > "${project}/.release-flow.json"
  t_run bash "${action}"
  assert_rc 3 "unsafe adapter: ${path}"
done
cp "${ROOT}/examples/shell/.release-flow.json" "${project}/.release-flow.json"
mv "${project}/tools/adapter.sh" "${project}/saved.sh"
t_run bash "${action}"
assert_rc 3 'missing adapter rejected'
ln -s ../saved.sh "${project}/tools/adapter.sh"
t_run bash "${action}"
assert_rc 3 'symlink file rejected even within root'
rm "${project}/tools/adapter.sh"
mv "${project}/saved.sh" "${project}/tools/adapter.sh"
mv "${project}/tools" "${TF_TMP}/external"
ln -s "${TF_TMP}/external" "${project}/tools"
t_run bash "${action}"
assert_rc 3 'symlink parent escape rejected'
rm "${project}/tools"
mv "${TF_TMP}/external" "${project}/tools"
for dir in '../escape' '/tmp' 'tools/..'; do
  RF_INPUT_PROJECT_DIRECTORY="${dir}" t_run bash "${action}"
  assert_rc 3 "unsafe project directory: ${dir}"
done
RF_INPUT_ADAPTER=other.sh t_run bash "${action}"
assert_rc 3 'adapter/config mismatch rejected'

t_case 'Malformed configuration and contracts fail closed'
for json in '{}' '{"schema_version":2}' '[]' '{broken' '{"publishers":{"unknown":{"required":true}}}'; do
  printf '%s' "${json}" > "${project}/.release-flow.json"
  t_run bash "${action}"
  assert_rc 3 'bad config rejected'
done
cp "${ROOT}/examples/shell/.release-flow.json" "${project}/.release-flow.json"
for filter in '.remote="--upload-pack=evil"' '.production_base="main"' '.test_base=.production_base'; do
  jq "${filter}" "${ROOT}/examples/shell/.release-flow.json" > "${project}/.release-flow.json"
  t_run bash "${action}"
  assert_rc 3 'unsafe Git configuration rejected'
done
cp "${ROOT}/examples/shell/.release-flow.json" "${project}/.release-flow.json"
sed '/release-flow-adapter: 1/d' "${ROOT}/examples/shell/tools/adapter.sh" > "${project}/tools/adapter.sh"
t_run bash "${action}"
assert_rc 3 'missing protocol declaration rejected'
cp "${ROOT}/examples/shell/tools/adapter.sh" "${project}/tools/adapter.sh"
printf '\nif then\n' >> "${project}/tools/adapter.sh"
t_run bash "${action}"
assert_rc 3 'invalid shell syntax rejected'
cp "${ROOT}/examples/shell/tools/adapter.sh" "${project}/tools/adapter.sh"
chmod -x "${project}/tools/adapter.sh"
t_run bash "${action}"
assert_rc 3 'nonexecutable adapter rejected'
chmod +x "${project}/tools/adapter.sh"
mv "${project}/tools/adapter.sh" "${project}/tools/adapter with spaces.sh"
jq '.adapter="tools/adapter with spaces.sh"' "${project}/.release-flow.json" > "${project}/new.json"
mv "${project}/new.json" "${project}/.release-flow.json"
t_run bash "${action}"
assert_rc 0 'adapter whitespace supported'

t_case 'Complete shell adapter packages reproducibly without Rust'
cd "${ROOT}/examples/shell"
t_run bash tools/adapter.sh verify
assert_rc 0 'shell verify'
SOURCE_DATE_EPOCH=1234567890 t_run bash tools/adapter.sh package 0.1.0 "${TF_TMP}/package-a"
assert_rc 0 'shell package'
SOURCE_DATE_EPOCH=1234567890 t_run bash tools/adapter.sh package 0.1.0 "${TF_TMP}/package-b"
assert_rc 0 'shell package repeat'
assert_eq "$(sha256sum "${TF_TMP}/package-a/hello-0.1.0.tar.gz" | cut -d' ' -f1)" "$(sha256sum "${TF_TMP}/package-b/hello-0.1.0.tar.gz" | cut -d' ' -f1)" 'reproducible bytes'
SOURCE_DATE_EPOCH=1234567890 t_run bash tools/adapter.sh package 0.1.0 "${TF_TMP}/package-a"
assert_rc nonzero 'nonempty output rejected'
t_finish
