#!/usr/bin/env bash
# Read-only publisher selection before any environment/credentials are used.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"
[[ $# -eq 2 ]] || rf_die 'Usage: plan.sh X.Y.Z [channel-or-empty]' 2
rf_require_tools jq
rf_semver_valid "$1" || rf_die "Invalid release version: $1" 3
channel="$2"
case "${channel}" in
  ''|github-release|oci|crates-io|docs|helm) ;;
  *) rf_die "Unknown publisher channel: ${channel}" 3 ;;
esac
rf_schema_check config .release-flow.json || rf_die 'Invalid .release-flow.json' 3
rf_config_load_text "$(cat .release-flow.json)"
channels="$(printf '%s' "${RF_CONFIG_JSON}" | jq -c --arg c "${channel}" \
  '[.publishers // {} | to_entries[] | select(.value != null) | .key | select($c == "" or . == $c)]')"
[[ "${channels}" != '[]' ]] || rf_die "No configured publishers selected${channel:+: ${channel}}" 3
for c in ${RF_CHANNELS}; do
  enabled="$(printf '%s' "${channels}" | jq --arg c "${c}" 'index($c) != null')"
  rf_kv "${c}" "${enabled}"
done
rf_kv channels "${channels}"
