#!/usr/bin/env bash
# Branch-aware deploy: prepare and push a release candidate whose policy is
# selected by the current branch.
#
#   test_base       -> test-only candidate  (release/test/X.Y.Z-<base12>)
#   production_base -> production candidate (release/X.Y.Z-<base12>)
#   anything else   -> rejected (exit 3) without touching Git
#
# Exit codes: 0 ok, 1 failure, 2 usage error, 3 branch policy rejection.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: release-deploy.sh [--project-dir DIR] <patch|minor|major>
EOF
  exit 2
}

die() {
  echo "$1" >&2
  exit "${2:-1}"
}

# ---------------------------------------------------------------------------
# Phase 1: Decide (read-only; never fetches, locks or writes under .git)
# ---------------------------------------------------------------------------

project_dir="."
bump=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)
      [[ $# -ge 2 ]] || usage
      project_dir="$2"
      shift 2
      ;;
    patch|minor|major)
      [[ -z "${bump}" ]] || usage
      bump="$1"
      shift
      ;;
    *)
      usage
      ;;
  esac
done
[[ -n "${bump}" ]] || usage

for tool in git jq; do
  command -v "${tool}" >/dev/null 2>&1 || die "Missing required tool: ${tool}"
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare_script="${script_dir}/release-prepare.sh"
[[ -f "${prepare_script}" ]] || die "Incomplete release-flow installation: ${prepare_script} is missing"

if ! top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || [[ -z "${top}" ]]; then
  die "Not inside a Git work tree: ${project_dir}"
fi
cd "${top}"

# Full ref, not --short: --short yields "heads/<branch>" when a tag shares the name.
full_ref="$(git symbolic-ref -q HEAD || true)"
if [[ ! "${full_ref}" =~ ^refs/heads/(.+)$ ]]; then
  head12="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  die "Refusing to deploy from a detached HEAD (${head12}): deploy policy is selected by branch. Check out the test or production base branch." 3
fi
branch="${BASH_REMATCH[1]}"

if [[ "${branch}" == "main" ]]; then
  die "Refusing to deploy from 'main': main receives only guarded release promotion and is never a candidate base." 3
fi

case "${branch}" in
  release/*)
    die "Refusing to deploy from '${branch}': '${branch}' is a release candidate branch; candidates are immutable and never used as a deploy base." 3
    ;;
esac

config_json="$(git show HEAD:.release-flow.json 2>/dev/null || true)"
[[ -n "${config_json}" ]] || die "Missing .release-flow.json at HEAD"

if ! printf '%s' "${config_json}" | jq -e 'type == "object"' >/dev/null 2>&1; then
  die "Invalid JSON in .release-flow.json at HEAD"
fi

cfg() {
  printf '%s' "${config_json}" | jq -r --arg k "$1" '.[$k] // empty | tostring'
}

schema_ver="$(cfg schema_version)"
[[ "${schema_ver}" == "1" ]] || die "Unsupported schema_version in .release-flow.json: ${schema_ver:-<missing>}"

cfg_project="$(cfg project)"
cfg_adapter="$(cfg adapter)"
cfg_remote="$(cfg remote)"
cfg_prod_base="$(cfg production_base)"
cfg_test_base="$(cfg test_base)"

if [[ -z "${cfg_project}" || -z "${cfg_adapter}" || -z "${cfg_remote}" || -z "${cfg_prod_base}" || -z "${cfg_test_base}" ]]; then
  die "Incomplete configuration in .release-flow.json (project, adapter, remote, production_base and test_base are required)"
fi

if [[ "${cfg_prod_base}" == "${cfg_test_base}" ]]; then
  die "production_base and test_base must differ (both are '${cfg_prod_base}')"
fi

for key in production_base test_base; do
  if [[ "${key}" == "production_base" ]]; then value="${cfg_prod_base}"; else value="${cfg_test_base}"; fi
  if [[ "${value}" == "main" ]]; then
    die "${key} must not be 'main': main receives only guarded release promotion"
  fi
  case "${value}" in
    release/*)
      die "Invalid base branch name for ${key}: '${value}' (release/* is reserved for candidates)"
      ;;
  esac
  if ! git check-ref-format --branch "${value}" >/dev/null 2>&1; then
    die "Invalid base branch name for ${key}: '${value}'"
  fi
done

if [[ "${branch}" == "${cfg_test_base}" ]]; then
  mode="test-only"
elif [[ "${branch}" == "${cfg_prod_base}" ]]; then
  mode="production"
else
  die "Refusing to deploy from '${branch}': deploy runs only on configured base branches. Allowed: '${cfg_test_base}' (test-only candidate), '${cfg_prod_base}' (production candidate)." 3
fi

head_sha="$(git rev-parse --verify HEAD)"

# ---------------------------------------------------------------------------
# Phase 2: Act (single preparation path; prepare re-validates everything)
# ---------------------------------------------------------------------------

set +e
out="$(bash "${prepare_script}" "${bump}" --mode "${mode}" --base "${branch}" --push --expect-base-commit "${head_sha}")"
rc=$?
set -e
# Prepare failures (including its usage errors) are deploy failures: exit 1, so
# exit 2 and 3 keep meaning deploy usage error and branch policy rejection.
if [[ "${rc}" -ne 0 ]]; then
  exit 1
fi

kv() {
  printf '%s\n' "${out}" | sed -n "s/^$1=//p"
}

project="$(kv project)"
version="$(kv version)"
out_mode="$(kv mode)"
base_branch="$(kv base_branch)"
base_commit="$(kv base_commit)"
candidate_branch="$(kv candidate_branch)"
candidate_commit="$(kv candidate_commit)"
pushed="$(kv pushed)"

if [[ -z "${project}" || -z "${version}" || -z "${base_commit}" || -z "${candidate_branch}" || \
      -z "${candidate_commit}" || "${pushed}" != "true" || "${out_mode}" != "${mode}" || \
      "${base_branch}" != "${branch}" || "${base_commit}" != "${head_sha}" ]]; then
  echo "internal contract violation: unexpected release-prepare.sh output:" >&2
  printf '%s\n' "${out}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Phase 3: Report
# ---------------------------------------------------------------------------

ci_url=""
remote_url="$(git config --get "remote.${cfg_remote}.url" 2>/dev/null || true)"
slug=""
case "${remote_url}" in
  git@github.com:*) slug="${remote_url#git@github.com:}" ;;
  ssh://git@github.com/*) slug="${remote_url#ssh://git@github.com/}" ;;
  https://github.com/*) slug="${remote_url#https://github.com/}" ;;
esac
if [[ -n "${slug}" ]]; then
  slug="${slug%/}"
  slug="${slug%.git}"
  if [[ "${slug}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    ci_url="https://github.com/${slug}/actions?query=branch%3A${candidate_branch//\//%2F}"
  fi
fi

cat <<EOF
project=${project}
version=${version}
mode=${mode}
base_branch=${base_branch}
base_commit=${base_commit}
candidate_branch=${candidate_branch}
candidate_commit=${candidate_commit}
pushed=true
remote=${cfg_remote}
ci_url=${ci_url}
EOF

{
  echo "Deployed ${mode} candidate ${version} for ${project}"
  echo "  base:      ${base_branch} @ ${base_commit:0:12}"
  echo "  candidate: ${candidate_branch} @ ${candidate_commit:0:12}"
  echo "  remote:    ${cfg_remote} (create-only push; candidate CI triggered)"
  if [[ -n "${ci_url}" ]]; then
    echo "  ci:        ${ci_url}"
  fi
  echo "  The local candidate branch is kept; delete it when done: git branch -D ${candidate_branch}"
  if [[ "${mode}" == "test-only" ]]; then
    echo "Test-only candidates are never promotable to production."
  else
    echo "Promotion is a separate, explicitly authorized step."
  fi
} >&2
