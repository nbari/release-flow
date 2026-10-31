#!/usr/bin/env bash
# Owner setup, never invoked by workflows, validation, status or plan.
# github-bootstrap.sh OWNER/REPO [--apply]
# Default prints the proposed configuration; --apply requires Administration
# write and enables immutable releases plus an append-only metadata branch.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
[[ $# -ge 1 && $# -le 2 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || rf_die 'Usage: github-bootstrap.sh OWNER/REPO [--apply]' 2
repo="$1"
apply="${2:-}"
[[ -z "${apply}" || "${apply}" == --apply ]] || rf_die 'Expected --apply' 2
[[ "${GITHUB_ACTIONS:-}" != true ]] || rf_die 'Run owner setup locally, never with a workflow token' 3
echo "Repository: ${repo}"
echo 'Enable immutable releases; protect release-flow-storage against deletion and force pushes.'
[[ "${apply}" == --apply ]] || exit 0
rf_require_tools gh jq
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
gh api --hostname github.com --method PUT "repos/${repo}/immutable-releases"
gh api --hostname github.com --paginate "repos/${repo}/rulesets?per_page=100" \
  --jq '.[]' | jq -s '[.[] | select(.name == "release-flow-storage-integrity")]' > "${WORK}/existing.json"
[[ "$(jq length "${WORK}/existing.json")" -le 1 ]] || rf_die 'Multiple storage rulesets found; resolve the duplicate owner configuration' 3
cat > "${WORK}/rule.json" <<'JSON'
{
  "name": "release-flow-storage-integrity",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {"ref_name": {"include": ["refs/heads/release-flow-storage"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}]
}
JSON
if [[ "$(jq length "${WORK}/existing.json")" == 1 ]]; then
  id="$(jq -er '.[0].id | select(type == "number")' "${WORK}/existing.json")"
  gh api --hostname github.com --method PUT "repos/${repo}/rulesets/${id}" --input "${WORK}/rule.json" >/dev/null
else
  gh api --hostname github.com --method POST "repos/${repo}/rulesets" --input "${WORK}/rule.json" >/dev/null
fi
echo 'GitHub storage configured. No branch, tag or release was created.'
