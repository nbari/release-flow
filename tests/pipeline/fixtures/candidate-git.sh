#!/usr/bin/env bash
# Real bare Git transport with only the GitHub URL identity query substituted.
set -euo pipefail
if [[ "${1:-}" == remote && "${2:-}" == get-url ]]; then
  printf 'git@github.com:acme/candidates.git\n'
  if [[ "$*" == *--push* && "${MOCK_CANDIDATE_BAD_PUSH:-}" == true ]]; then
    printf 'git@github.com:other/repository.git\n'
  fi
  exit 0
fi
if [[ "${1:-}" == push && -n "${MOCK_CANDIDATE_REF_RACE:-}" && -f "$MOCK_CANDIDATE_REF_RACE" ]]; then
  read -r ref commit < "$MOCK_CANDIDATE_REF_RACE"
  rm "$MOCK_CANDIDATE_REF_RACE"
  "$RF_REAL_GIT" --git-dir="${TF_TMP}/candidates.git" update-ref "$ref" "$commit"
fi
exec "$RF_REAL_GIT" "$@"
