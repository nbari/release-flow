#!/usr/bin/env bash
# Composite Action entrypoint. All executable code comes from this directory;
# consumer files are data only. Inputs arrive as environment values, never code.
set -euo pipefail
unset RF_COMMON_LOADED RF_SCHEMA_LOADED
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"
# shellcheck source=scripts/lib/project.sh
source "${RF_SCRIPTS}/lib/project.sh"

[[ "${RF_INPUT_OPERATION:-validate}" == validate ]] || rf_die "Unsupported operation; expected validate" 2
rf_require_tools bash git jq grep cat awk sed
rf_git_version_ok 2 31 || rf_die "git >= 2.31 is required" 1
[[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]] || rf_die "GITHUB_WORKSPACE must identify the checked-out consumer repository" 3
workspace="$(cd "${GITHUB_WORKSPACE}" && pwd -P)"
relative="${RF_INPUT_PROJECT_DIRECTORY:-.}"
if [[ "${relative}" == . ]]; then
  project_dir="${workspace}"
else
  project_dir="$(rf_project_path "${workspace}" "${relative}")"
fi
[[ -d "${project_dir}" ]] || rf_die "Project directory does not exist: ${relative}" 3
rf_project_config "${project_dir}" "${RF_INPUT_ADAPTER:-}"
rf_adapter_contract "${project_dir}/${RF_ADAPTER}"

revision="${RF_ACTION_REF:-}"
if [[ ! "${revision}" =~ ${RF_RE_COMMIT} ]]; then
  action_root="$(cd "${RF_SCRIPTS}/.." && pwd -P)"
  git_root="$(git -C "${action_root}" rev-parse --show-toplevel 2>/dev/null || true)"
  revision=unresolved
  if [[ "${git_root}" == "${action_root}" ]]; then
    revision="$(git -C "${action_root}" rev-parse HEAD)"
  fi
fi
result="$(jq -cn --arg project "$(rf_cfg .project)" --arg directory "${project_dir}" \
  --arg adapter "${RF_ADAPTER}" --arg revision "${revision}" \
  --arg repository "$(rf_cfg .pipeline.repository)" --arg sha "$(rf_cfg .pipeline.sha)" \
  '{valid:true,project:$project,project_directory:$directory,adapter:$adapter,adapter_protocol:1,
    runtime_revision:$revision,pipeline_repository:$repository,pipeline_sha:$sha,adapter_executed:false}')"
rf_kv project "$(rf_cfg .project)"
rf_kv project-directory "${project_dir}"
rf_kv adapter "${RF_ADAPTER}"
rf_kv runtime-revision "${revision}"
rf_kv validation-json "${result}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    rf_kv project "$(rf_cfg .project)"
    rf_kv project-directory "${project_dir}"
    rf_kv adapter "${RF_ADAPTER}"
    rf_kv runtime-revision "${revision}"
    rf_kv validation-json "${result}"
  } >> "${GITHUB_OUTPUT}"
fi
