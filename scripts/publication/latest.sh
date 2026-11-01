#!/usr/bin/env bash
# Is <version> the latest promoted release?
#
#   latest.sh [--project-dir DIR] --version X.Y.Z      prints true or false
#
# false when any higher SemVer tag on the push remote is a promoted release:
# it peels to a commit contained in the remote main branch and its signature
# verifies (promotion.signature_verification). Anything else (unsigned tags,
# tags off main) never demotes <version>.
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
  echo "Usage: latest.sh [--project-dir DIR] --version X.Y.Z" >&2
  exit 2
}

project_dir="."
version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --version) [[ $# -ge 2 ]] || usage; version="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "${version}" ]] || usage
rf_semver_valid "${version}" || rf_die "Invalid version: ${version}" 2

top="$(git -C "${project_dir}" rev-parse --show-toplevel 2>/dev/null)" || rf_die "Not inside a Git work tree: ${project_dir}" 2
cd "${top}"
rf_schema_check config .release-flow.json || rf_die "latest: invalid .release-flow.json" 3
rf_config_load_text "$(cat .release-flow.json)"
rf_git_auth_env
remote="$(rf_cfg .promotion.push_remote)"
[[ -n "${remote}" ]] || remote="$(rf_cfg .remote)"
main_branch="$(rf_cfg .promotion.main_branch)"
[[ -n "${main_branch}" ]] || main_branch="main"
mode="$(rf_cfg .promotion.signature_verification)"
[[ -n "${mode}" ]] || mode="github"
repository="$(rf_cfg .repository)"
signers="$(rf_cfg .promotion.allowed_signers)"

ls="$(git ls-remote "${remote}" "refs/heads/${main_branch}" 'refs/tags/*')" || rf_die "latest: cannot query ${remote}" 1
main_sha="$(rf_ls_remote_value "${ls}" "refs/heads/${main_branch}")"
[[ -n "${main_sha}" ]] || rf_die "latest: ${remote} has no ${main_branch} branch" 1

higher=""
while IFS= read -r t; do
  [[ -n "${t}" ]] || continue
  if [[ "$(rf_semver_cmp "${t}" "${version}")" == "1" ]]; then
    higher+="${t}"$'\n'
  fi
done <<< "$(rf_semver_tags "${ls}")"

if [[ -z "${higher}" ]]; then
  echo true
  exit 0
fi

refspecs=("refs/heads/${main_branch}")
while IFS= read -r t; do
  [[ -n "${t}" ]] && refspecs+=("refs/tags/${t}")
done <<< "${higher}"
rf_git_fetch "${remote}" "${refspecs[@]}" || rf_die "latest: cannot fetch tags from ${remote}" 1

while IFS= read -r t; do
  [[ -n "${t}" ]] || continue
  obj="$(rf_ls_remote_value "${ls}" "refs/tags/${t}")"
  peeled="$(rf_ls_remote_value "${ls}" "refs/tags/${t}^{}")"
  [[ -n "${peeled}" ]] || continue
  git merge-base --is-ancestor "${peeled}" "${main_sha}" 2>/dev/null || continue
  rf_tag_verify_signature "${obj}" "${mode}" "${repository}" "${peeled}" "${signers}" 2>/dev/null || continue
  echo false
  exit 0
done <<< "${higher}"
echo true
