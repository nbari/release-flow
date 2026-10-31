#!/usr/bin/env bash
# Pin release-flow scripts to the workflow's own commit.
#
#   pipeline-pin.sh [--project-dir DIR] --checkout DIR --dest DIR \
#     --workflow-repository R --workflow-ref REF --workflow-sha SHA \
#     --repository GITHUB_REPOSITORY --commit GITHUB_SHA
#
# Call mode (the workflow repo is not the caller's repo) requires a full-SHA
# uses: pin that matches .release-flow.json "pipeline". Local mode rejects a
# declared pipeline. Empty job.workflow_* (for example GHES) is local mode
# only, and only when the checkout HEAD equals --commit.
#
# All checks run before the checkout is moved. stdout (key=value):
#   pipeline_mode pipeline_repository pipeline_sha
# Exit: 0 ok, 1 environment, 2 usage, 3 pin/policy rejection.
#
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF' >&2
Usage: pipeline-pin.sh [--project-dir DIR] --checkout DIR --dest DIR --workflow-repository R --workflow-ref REF --workflow-sha SHA --repository GITHUB_REPOSITORY --commit GITHUB_SHA
EOF
  exit 2
}

project_dir="."
checkout=""
dest=""
wf_repo=""
wf_ref=""
wf_sha=""
repository=""
commit=""
seen_checkout=0
seen_dest=0
seen_wf_repo=0
seen_wf_ref=0
seen_wf_sha=0
seen_repository=0
seen_commit=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 && -n "$2" ]] || usage; project_dir="$2"; shift 2 ;;
    --checkout) [[ $# -ge 2 ]] || usage; checkout="$2"; seen_checkout=1; shift 2 ;;
    --dest) [[ $# -ge 2 ]] || usage; dest="$2"; seen_dest=1; shift 2 ;;
    --workflow-repository) [[ $# -ge 2 ]] || usage; wf_repo="$2"; seen_wf_repo=1; shift 2 ;;
    --workflow-ref) [[ $# -ge 2 ]] || usage; wf_ref="$2"; seen_wf_ref=1; shift 2 ;;
    --workflow-sha) [[ $# -ge 2 ]] || usage; wf_sha="$2"; seen_wf_sha=1; shift 2 ;;
    --repository) [[ $# -ge 2 ]] || usage; repository="$2"; seen_repository=1; shift 2 ;;
    --commit) [[ $# -ge 2 ]] || usage; commit="$2"; seen_commit=1; shift 2 ;;
    *) usage ;;
  esac
done

if [[ "${seen_checkout}" -eq 0 || "${seen_dest}" -eq 0 || "${seen_wf_repo}" -eq 0 || "${seen_wf_ref}" -eq 0 \
      || "${seen_wf_sha}" -eq 0 || "${seen_repository}" -eq 0 || "${seen_commit}" -eq 0 \
      || -z "${checkout}" || -z "${dest}" ]]; then
  usage
fi

rf_require_tools git jq

cfg="${project_dir}/.release-flow.json"
if [[ ! -f "${cfg}" ]]; then
  rf_die "Missing .release-flow.json" 1
fi
if ! has_pipeline="$(jq -r 'if type != "object" then "bad" elif has("pipeline") then "yes" else "no" end' "${cfg}" 2>/dev/null)"; then
  rf_die "Cannot read .release-flow.json" 1
fi
if [[ "${has_pipeline}" == "bad" ]]; then
  rf_die "Cannot read .release-flow.json" 1
fi

decl_repo=""
decl_sha=""
if [[ "${has_pipeline}" == "yes" ]]; then
  ptype="$(jq -r '.pipeline | type' "${cfg}" 2>/dev/null || true)"
  decl_repo="$(jq -r '.pipeline.repository // empty' "${cfg}" 2>/dev/null || true)"
  decl_sha="$(jq -r '.pipeline.sha // empty' "${cfg}" 2>/dev/null || true)"
  if [[ "${ptype}" != "object" || -z "${decl_repo}" || -z "${decl_sha}" || ! "${decl_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    rf_die ".release-flow.json pipeline is incomplete or pipeline.sha is not a full commit SHA" 3
  fi
fi

if ! head="$(git -C "${checkout}" rev-parse HEAD 2>/dev/null)"; then
  rf_die "Cannot read pipeline checkout HEAD" 1
fi

mode=""
pipe_repo=""
pipe_sha=""
if [[ -z "${wf_sha}" ]]; then
  if [[ -n "${wf_repo}" || -n "${wf_ref}" ]]; then
    rf_die "job.workflow_sha is empty but job.workflow_repository or job.workflow_ref is set" 3
  fi
  if [[ -n "${decl_repo}" ]]; then
    rf_die "a pinned pipeline requires job.workflow_* (github.com)" 3
  fi
  if [[ "${head}" != "${commit}" ]]; then
    rf_die "pipeline checkout HEAD (${head}) != ${commit}" 3
  fi
  mode="local"
  pipe_sha="${head}"
else
  if [[ ! "${wf_sha}" =~ ^[0-9a-f]{40}$ ]]; then
    rf_die "job.workflow_sha is not a full commit SHA: ${wf_sha}" 3
  fi
  if [[ "${head}" != "${wf_sha}" ]]; then
    rf_die "pipeline checkout HEAD (${head}) != job.workflow_sha (${wf_sha})" 3
  fi
  if [[ "${wf_repo}" == "${repository}" ]]; then
    if [[ -n "${decl_repo}" ]]; then
      rf_die ".release-flow.json declares pipeline ${decl_repo}@${decl_sha} but this run uses the repository's own workflow" 3
    fi
    mode="local"
    pipe_repo="${wf_repo}"
    pipe_sha="${wf_sha}"
  else
    prefix="${wf_repo}/.github/workflows/"
    case "${wf_ref}" in
      "${prefix}"*) ;;
      *) rf_die "workflow ref does not start with ${prefix}" 3 ;;
    esac
    suffix="${wf_ref##*@}"
    if [[ "${suffix}" == "${wf_ref}" || "${suffix}" != "${wf_sha}" ]]; then
      rf_die "pin release-flow by full commit SHA in uses:, got @${suffix}" 3
    fi
    if [[ -z "${decl_repo}" ]]; then
      rf_die ".release-flow.json declares no pipeline" 3
    fi
    if [[ "${decl_repo}" != "${wf_repo}" || "${decl_sha}" != "${wf_sha}" ]]; then
      rf_die ".release-flow.json pipeline ${decl_repo}@${decl_sha} does not match the running workflow ${wf_repo}@${wf_sha}" 3
    fi
    mode="call"
    pipe_repo="${wf_repo}"
    pipe_sha="${wf_sha}"
  fi
fi

if [[ -e "${dest}" ]]; then
  rf_die "pipeline destination already exists: ${dest}" 1
fi
if ! mv "${checkout}" "${dest}"; then
  rf_die "cannot move pipeline checkout to ${dest}" 1
fi

rf_kv pipeline_mode "${mode}"
rf_kv pipeline_repository "${pipe_repo}"
rf_kv pipeline_sha "${pipe_sha}"
