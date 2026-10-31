#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir -p "${TF_TMP}/consumer"
cd "${TF_TMP}/consumer"
jq '.publishers={"github-release":{required:true},"docs":{required:false,artifact:"docs.tar.gz",uri:"file:///tmp/docs"}}' \
  "${ROOT}/examples/shell/.release-flow.json" > .release-flow.json
t_case 'Publisher plan fails closed before credentials or side effects'
t_run bash "${ROOT}/scripts/publication/plan.sh" 1.2.3 ''
assert_rc 0 'all configured channels selected'
assert_contains "${T_OUT}" 'github-release=true' 'required channel selected'
assert_contains "${T_OUT}" 'docs=true' 'optional configured channel selected'
assert_contains "${T_OUT}" 'oci=false' 'unconfigured channel excluded'
t_run bash "${ROOT}/scripts/publication/plan.sh" 1.2.3 docs
assert_rc 0 'independent docs retry'
assert_contains "${T_OUT}" 'github-release=false' 'retry does not run sibling publisher'
for channel in unknown 'github-release docs' $'docs\nx=y' oci; do
  t_run bash "${ROOT}/scripts/publication/plan.sh" 1.2.3 "${channel}"
  assert_rc 3 "invalid or unconfigured selection ${channel}"
done
t_run bash "${ROOT}/scripts/publication/plan.sh" main docs
assert_rc 3 'invalid version rejected'
jq '.publishers={}' .release-flow.json > empty.json
mv empty.json .release-flow.json
t_run bash "${ROOT}/scripts/publication/plan.sh" 1.2.3 ''
assert_rc 3 'empty configuration cannot succeed as publication'
t_finish
