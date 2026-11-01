#!/usr/bin/env bash
# Print the candidate.yml package matrix for the adapter:
#
#   candidate-targets.sh --adapter <path>     (run from the repository root)
#
# The adapter's optional `targets` subcommand prints a JSON array of
# {"target": "<name>", "runner": "<runs-on label>"}. An adapter without it
# (exit 2) gets one leg that packages everything:
#   {"include":[{"target":"","runner":"ubuntu-24.04"}]}
# Output is compact {"include": [...]} for fromJSON().
# Exit codes: 0 ok, 1 adapter failure or invalid/duplicate targets, 2 usage.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

usage() {
  echo "Usage: candidate-targets.sh --adapter <path>" >&2
  exit 2
}

adapter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --adapter) [[ $# -ge 2 ]] || usage; adapter="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "${adapter}" ]] || usage
[[ -x "${adapter}" ]] || { echo "Adapter '${adapter}' is not executable" >&2; exit 1; }
case "${adapter}" in
  /*) ;;
  *) adapter="./${adapter}" ;;
esac

rc=0
out="$("${adapter}" targets)" || rc=$?
if (( rc == 2 )); then
  echo "Adapter has no targets subcommand; packaging every artifact in one leg" >&2
  printf '{"include":[{"target":"","runner":"ubuntu-24.04"}]}\n'
  exit 0
fi
if (( rc != 0 )); then
  echo "Adapter targets failed (exit ${rc})" >&2
  exit 1
fi

if ! errors="$(printf '%s' "${out}" | jq -r '
    if type != "array" or length == 0 then "targets must be a non-empty JSON array"
    else
      (.[] | select(type != "object" or (keys | sort) != ["runner", "target"]
                    or (.target | type) != "string" or (.target | test("^[A-Za-z0-9._+-]+$") | not)
                    or (.runner | type) != "string" or (.runner | test("^[A-Za-z0-9._-]+$") | not))
           | "invalid target entry: " + tojson),
      (if all(.[]; type == "object") then map(.target) | group_by(tostring) | map(select(length > 1) | .[0]) | .[] | "duplicate target: " + tostring else empty end)
    end' 2>/dev/null)"; then
  echo "Adapter targets output is not valid JSON" >&2
  exit 1
fi
if [[ -n "${errors}" ]]; then
  printf '%s\n' "${errors}" >&2
  exit 1
fi
printf '%s' "${out}" | jq -c '{include: .}'
