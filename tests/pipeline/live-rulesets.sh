#!/usr/bin/env bash
# Read-only integration check of real GitHub rules. Explicitly invoked, not
# part of run.sh: needs authenticated GitHub access and configured rulesets.
set -euo pipefail
if [[ $# -lt 1 || $# -gt 4 ]]; then
  echo 'Usage: live-rulesets.sh OWNER/REPO [MAIN [DEVELOP [REQUIRED_JOB]]]' >&2
  exit 2
fi
repository="$1"
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid repository' >&2; exit 2; }
for tool in gh jq; do
  command -v "${tool}" >/dev/null || { echo "Missing required tool: ${tool}" >&2; exit 1; }
done
# shellcheck source=scripts/lib/github.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/github.sh"
rf_gh_protection_ok "${repository}" "${2:-main}" "${3:-develop}" "${4:-Candidate OK}"
for branch in release/0.0.1-abcdef012345 release/test/0.0.1-abcdef012345; do
  rules="$(gh api "repos/${repository}/rules/branches/${branch//\//%2F}")"
  if ! printf '%s' "${rules}" | jq -e '
    [.[].type] | index("update") != null and index("non_fast_forward") != null' >/dev/null; then
    echo "Candidate immutability is not enforced on ${branch}" >&2
    exit 1
  fi
  printf 'Verified immutable candidate policy: %s\n' "${branch}"
done
echo 'Verified promotion and candidate rules on GitHub'
