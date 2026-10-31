#!/usr/bin/env bash
set -euo pipefail
endpoint=''
for arg in "$@"; do case "$arg" in repos/*) endpoint="$arg" ;; esac; done
if [[ "$endpoint" == */branches/*/protection ]]; then
  if [[ "${MOCK_CANDIDATE_LEGACY:-}" == true ]]; then echo '{}'; exit 0; fi
  echo '{"status":"404"}'; exit 1
fi
if [[ "$endpoint" == */actions/runs\?branch=* && -n "${MOCK_CANDIDATE_CI_RACE:-}" ]]; then
  count=0
  [[ ! -f "$MOCK_CANDIDATE_CI_RACE" ]] || count="$(cat "$MOCK_CANDIDATE_CI_RACE")"
  printf '%s\n' "$((count+1))" > "$MOCK_CANDIDATE_CI_RACE"
  if (( count>0 )); then echo '{"workflow_runs":[{"status":"in_progress"}]}'; exit 0; fi
fi
exec "${ROOT}/tests/pipeline/fixtures/mock-gh.sh" "$@"
