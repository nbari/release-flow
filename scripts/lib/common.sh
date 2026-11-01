# shellcheck shell=bash
# Shared helpers for release-flow scripts. Sourced, never executed.
# Must stay compatible with bash 3.2 (macOS default): no associative arrays,
# mapfile, ${x,,} or [[ -v ]].

if [[ -n "${RF_COMMON_LOADED:-}" ]]; then
  return 0
fi
RF_COMMON_LOADED=1

RF_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export RF_SCRIPTS

RF_RE_COMMIT='^[0-9a-f]{40}$'
RF_RE_DIGEST='^[0-9a-f]{64}$'
RF_RE_VERSION='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
RF_RE_KEY='^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$'
RF_CHANNELS="github-release oci crates-io docs helm"

rf_log() {
  printf '%s\n' "$*" >&2
}

# rf_die <message> [exit-code]
rf_die() {
  printf '%s\n' "$1" >&2
  exit "${2:-1}"
}

rf_require_tools() {
  local t
  for t in "$@"; do
    command -v "${t}" >/dev/null 2>&1 || rf_die "Missing required tool: ${t}" 1
  done
}

rf_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

rf_have_sha256() {
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1
}

rf_file_size() {
  wc -c < "$1" | tr -d ' '
}

rf_semver_valid() {
  [[ "$1" =~ ${RF_RE_VERSION} ]]
}

# rf_semver_cmp <a> <b>: prints -1, 0 or 1.
rf_semver_cmp() {
  local a1 a2 a3 b1 b2 b3
  IFS='.' read -r a1 a2 a3 <<< "$1"
  IFS='.' read -r b1 b2 b3 <<< "$2"
  if (( 10#${a1} != 10#${b1} )); then
    (( 10#${a1} < 10#${b1} )) && echo -1 || echo 1
  elif (( 10#${a2} != 10#${b2} )); then
    (( 10#${a2} < 10#${b2} )) && echo -1 || echo 1
  elif (( 10#${a3} != 10#${b3} )); then
    (( 10#${a3} < 10#${b3} )) && echo -1 || echo 1
  else
    echo 0
  fi
}

# rf_config_load_text <json>: validates that the text is a JSON object and
# stores it in RF_CONFIG_JSON.
rf_config_load_text() {
  if ! printf '%s' "$1" | jq -e 'type == "object"' >/dev/null 2>&1; then
    return 1
  fi
  RF_CONFIG_JSON="$1"
  export RF_CONFIG_JSON
}

# rf_cfg <jq-path>: the value at the path (strings raw, other values as JSON),
# or nothing when absent or null.
rf_cfg() {
  printf '%s' "${RF_CONFIG_JSON:-{\}}" | jq -r "($1) as \$v | if \$v == null then empty elif (\$v | type) == \"string\" then \$v else (\$v | tojson) end"
}

# rf_tpl <template> <project> <version>: expands {project} and {version}.
rf_tpl() {
  local out="$1"
  out="${out//\{project\}/$2}"
  out="${out//\{version\}/$3}"
  printf '%s' "${out}"
}

# rf_storage_uri: RELEASE_FLOW_STORAGE_URI, else storage.uri from the config.
rf_storage_uri() {
  if [[ -n "${RELEASE_FLOW_STORAGE_URI:-}" ]]; then
    printf '%s' "${RELEASE_FLOW_STORAGE_URI}"
  else
    rf_cfg '.storage.uri'
  fi
}

# rf_storage <op> [args...]: storage.sh bound to the configured URI, region and
# endpoint.
rf_storage() {
  local uri region endpoint
  uri="$(rf_storage_uri)"
  region="$(rf_cfg '.storage.region')"
  endpoint="$(rf_cfg '.storage.endpoint')"
  bash "${RF_SCRIPTS}/storage/storage.sh" --uri "${uri}" --region "${region}" --endpoint "${endpoint}" "$@"
}

# rf_lock_acquire <dir> [label]: exclusive mkdir lock with a pid file. A lock
# whose pid is dead is reclaimed. Returns 9 when held by a live process.
rf_lock_acquire() {
  local dir="$1" label="${2:-release-flow}" pid stale
  mkdir -p "$(dirname "${dir}")"
  if mkdir "${dir}" 2>/dev/null; then
    printf '%s\n' "$$" > "${dir}/pid"
    return 0
  fi
  pid="$(cat "${dir}/pid" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && ! kill -0 "${pid}" 2>/dev/null; then
    stale="${dir}.stale.$$"
    if mv "${dir}" "${stale}" 2>/dev/null; then
      rm -rf "${stale}"
      rf_log "reclaimed stale ${label} lock (pid ${pid} is not running): ${dir}"
      if mkdir "${dir}" 2>/dev/null; then
        printf '%s\n' "$$" > "${dir}/pid"
        return 0
      fi
    fi
  fi
  rf_log "${label} lock is held${pid:+ by pid ${pid}}: ${dir}"
  return 9
}

rf_lock_release() {
  local dir="$1" pid
  [[ -d "${dir}" ]] || return 0
  pid="$(cat "${dir}/pid" 2>/dev/null || true)"
  if [[ "${pid}" == "$$" ]]; then
    rm -rf "${dir}"
  fi
}

# rf_atomic_write <dest> <src>: copy then rename within the destination dir.
rf_atomic_write() {
  local dest="$1" src="$2" tmp
  tmp="$(dirname "${dest}")/.$(basename "${dest}").tmp.$$"
  cp "${src}" "${tmp}"
  mv "${tmp}" "${dest}"
}

rf_now_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

rf_now_epoch() {
  date -u +%s
}

# rf_random_hex <bytes>
rf_random_hex() {
  od -An -tx1 -N "$1" /dev/urandom | tr -d ' \n'
}

# rf_kv <key> <value>: one key=value line; values never contain newlines.
rf_kv() {
  case "$2" in
    *$'\n'*) rf_die "internal error: value for ${1} contains a newline" 1 ;;
  esac
  printf '%s=%s\n' "$1" "$2"
}

# rf_git_auth_env: when RELEASE_FLOW_GIT_TOKEN is set, authenticate git HTTPS
# requests to github.com through the environment, never through argv.
rf_git_auth_env() {
  local n basic
  [[ -n "${RELEASE_FLOW_GIT_TOKEN:-}" ]] || return 0
  n="${GIT_CONFIG_COUNT:-0}"
  basic="$(printf 'x-access-token:%s' "${RELEASE_FLOW_GIT_TOKEN}" | base64 | tr -d '\n')"
  export "GIT_CONFIG_KEY_${n}=http.https://github.com/.extraheader"
  export "GIT_CONFIG_VALUE_${n}=AUTHORIZATION: basic ${basic}"
  export GIT_CONFIG_COUNT=$(( n + 1 ))
}

# rf_git_version_ok <major> <minor>: git is at least the given version.
rf_git_version_ok() {
  local v maj min
  v="$(git --version 2>/dev/null | awk '{print $3}')"
  IFS='.' read -r maj min _ <<< "${v}"
  [[ "${maj}" =~ ^[0-9]+$ && "${min}" =~ ^[0-9]+$ ]] || return 1
  (( maj > $1 || (maj == $1 && min >= $2) ))
}

# rf_semver_tags <ls-remote-output>: stable SemVer tag names (no v prefix
# variants), one per line, highest first.
rf_semver_tags() {
  printf '%s\n' "$1" | awk '{print $2}' | sed -n 's|^refs/tags/\([0-9][0-9.]*\)$|\1|p' \
    | while IFS= read -r t; do
        if rf_semver_valid "${t}"; then printf '%s\n' "${t}"; fi
      done | sort -t. -k1,1nr -k2,2nr -k3,3nr
}

# rf_git_fetch <remote> <refspec>...: fetch objects without touching tags,
# FETCH_HEAD or the remote-tracking branches (--refmap= disables the
# opportunistic remote-tracking update).
rf_git_fetch() {
  git fetch --no-tags --no-write-fetch-head --refmap= --quiet "$@"
}

# rf_ls_remote_value <ls-remote-output> <ref>: the object id for the ref.
rf_ls_remote_value() {
  printf '%s\n' "$1" | awk -v r="$2" '$2 == r { print $1; exit }'
}

# rf_push_remote: promotion.push_remote, else remote.
rf_push_remote() {
  local r
  r="$(rf_cfg .promotion.push_remote)"
  [[ -n "${r}" ]] || r="$(rf_cfg .remote)"
  printf '%s' "${r}"
}

# rf_channel_cfg <jq-path>: like rf_cfg, over RF_CHANNEL_CONFIG (the publisher's
# block of .release-flow.json).
rf_channel_cfg() {
  printf '%s' "${RF_CHANNEL_CONFIG:-{\}}" | jq -r "($1) as \$v | if \$v == null then empty elif (\$v | type) == \"string\" then \$v else (\$v | tojson) end"
}

# rf_release_artifact <template>: prints "<path><TAB><sha256>" of the release
# artifact named by the template (expanded for RF_PROJECT/RF_VERSION); fails
# with exit-worthy 4 when the release has no such artifact.
rf_release_artifact() {
  local name sha
  name="$(rf_tpl "$1" "${RF_PROJECT}" "${RF_VERSION}")"
  sha="$(jq -r --arg n "${name}" '.artifacts[] | select(.name == $n) | .sha256' "${RF_RELEASE_DIR}/artifacts/manifest.json")"
  if [[ -z "${sha}" || ! -f "${RF_RELEASE_DIR}/artifacts/${name}" ]]; then
    echo "release ${RF_VERSION} has no artifact ${name}" >&2
    return 4
  fi
  printf '%s\t%s\n' "${RF_RELEASE_DIR}/artifacts/${name}" "${sha}"
}

# rf_publication_state <status-json> <publishers-json>: PUBLISHED when every
# required channel succeeded, otherwise PROMOTED. Optional channels never
# demote the release.
rf_publication_state() {
  jq -nr --argjson s "$1" --argjson p "$2" '
    [ $p | to_entries[] | select(.value.required == true) | .key ] as $req
    | if all($req[]; ($s.channels[.].state // "pending") == "succeeded")
      then "PUBLISHED" else "PROMOTED" end'
}
