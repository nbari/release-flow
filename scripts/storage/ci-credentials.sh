#!/usr/bin/env bash
# Configure storage credentials inside GitHub Actions.
#
#   ci-credentials.sh [--uri URI]
#
# file:// needs no credentials; github:// uses the job/operator GH_TOKEN
# or gh login directly (no AWS credential exchange). For s3:// storage:
#   - RELEASE_FLOW_AWS_ROLE_ARN set: exchange the job's GitHub OIDC token
#     (audience sts.amazonaws.com) for temporary credentials with
#     `aws sts assume-role-with-web-identity` (requires `id-token: write`);
#   - otherwise RELEASE_FLOW_S3_ACCESS_KEY_ID / RELEASE_FLOW_S3_SECRET_ACCESS_KEY
#     are exported as static keys.
# Secrets never appear on a command line (visible in the process table): the
# OIDC request header and the web-identity token pass through private 0600
# files (`curl -H @file`, `--web-identity-token file://...`), removed on exit.
# Credentials are masked and appended to GITHUB_ENV for later steps.
#
# Exit codes: 0 ok, 1 missing credentials or exchange failure, 2 usage.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

uri=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uri) [[ $# -ge 2 ]] || rf_die "Usage: ci-credentials.sh [--uri URI]" 2; uri="$2"; shift 2 ;;
    *) rf_die "Usage: ci-credentials.sh [--uri URI]" 2 ;;
  esac
done

if [[ -z "${uri}" ]]; then
  uri="${RELEASE_FLOW_STORAGE_URI:-}"
fi
if [[ -z "${uri}" && -f .release-flow.json ]]; then
  uri="$(jq -r '.storage.uri // empty' .release-flow.json)"
fi

case "${uri}" in
  ''|file://*|github://*)
    echo "ci-credentials: no storage credentials needed${uri:+ for ${uri}}" >&2
    exit 0
    ;;
  s3://*) ;;
  *) rf_die "ci-credentials: unsupported storage URI: ${uri}" 1 ;;
esac

export_secret() {
  local name="$1" value="$2"
  [[ -n "${value}" ]] || rf_die "ci-credentials: empty value for ${name}" 1
  case "${value}" in
    *$'\n'*) rf_die "ci-credentials: value for ${name} contains a newline" 1 ;;
  esac
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${value}"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    printf '%s=%s\n' "${name}" "${value}" >> "${GITHUB_ENV}"
  fi
  export "${name}=${value}"
}

if [[ -n "${RELEASE_FLOW_AWS_ROLE_ARN:-}" ]]; then
  rf_require_tools curl aws jq
  if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" || -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]]; then
    rf_die "ci-credentials: no GitHub OIDC token available (the job needs permissions: id-token: write)" 1
  fi
  SECRETS="$(umask 077 && mktemp -d)"
  trap 'rm -rf "${SECRETS}"' EXIT
  (umask 077 && printf 'Authorization: bearer %s\n' "${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" > "${SECRETS}/request-header")
  chmod 0600 "${SECRETS}/request-header"
  token_json="$(curl -fsS -H "@${SECRETS}/request-header" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sts.amazonaws.com")" \
    || rf_die "ci-credentials: OIDC token request failed" 1
  web_token="$(printf '%s' "${token_json}" | jq -r '.value // empty')"
  [[ -n "${web_token}" ]] || rf_die "ci-credentials: OIDC response carried no token" 1
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::add-mask::${web_token}"
  fi
  (umask 077 && printf '%s' "${web_token}" > "${SECRETS}/web-identity-token")
  chmod 0600 "${SECRETS}/web-identity-token"
  session="release-flow-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}"
  creds="$(AWS_PAGER="" aws sts assume-role-with-web-identity --output json \
    --role-arn "${RELEASE_FLOW_AWS_ROLE_ARN}" --role-session-name "${session}" \
    --web-identity-token "file://${SECRETS}/web-identity-token" --duration-seconds 3600)" \
    || rf_die "ci-credentials: assume-role-with-web-identity failed" 1
  rm -rf "${SECRETS}"
  export_secret AWS_ACCESS_KEY_ID "$(printf '%s' "${creds}" | jq -r '.Credentials.AccessKeyId // empty')"
  export_secret AWS_SECRET_ACCESS_KEY "$(printf '%s' "${creds}" | jq -r '.Credentials.SecretAccessKey // empty')"
  export_secret AWS_SESSION_TOKEN "$(printf '%s' "${creds}" | jq -r '.Credentials.SessionToken // empty')"
  echo "ci-credentials: assumed ${RELEASE_FLOW_AWS_ROLE_ARN} for ${uri}" >&2
elif [[ -n "${RELEASE_FLOW_S3_ACCESS_KEY_ID:-}" && -n "${RELEASE_FLOW_S3_SECRET_ACCESS_KEY:-}" ]]; then
  export_secret AWS_ACCESS_KEY_ID "${RELEASE_FLOW_S3_ACCESS_KEY_ID}"
  export_secret AWS_SECRET_ACCESS_KEY "${RELEASE_FLOW_S3_SECRET_ACCESS_KEY}"
  echo "ci-credentials: using static storage keys for ${uri}" >&2
else
  rf_die "ci-credentials: ${uri} needs RELEASE_FLOW_AWS_ROLE_ARN (OIDC) or RELEASE_FLOW_S3_ACCESS_KEY_ID and RELEASE_FLOW_S3_SECRET_ACCESS_KEY" 1
fi
