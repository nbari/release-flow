#!/usr/bin/env bash
# Mock GitHub CLI for release-flow pipeline tests. State lives under
# ${MOCK_GH_ROOT}:
#   api/<endpoint, chars outside [A-Za-z0-9._-] replaced by _>   GET responses
#   artifacts/<run>/<name>/                                     run artifacts
#   remotes/<owner_repo>                                        bare repo path (release --verify-tag)
#   releases/<owner_repo>/<id>/{meta.json,assets/}              release state
#   calls.log                                                   every invocation
# Releases endpoints (repos/R/releases?per_page=100, repos/R/releases/latest)
# are synthesized from the release state, with sha256 asset digests unless
# MOCK_GH_NO_DIGEST=1. The release list is paged by MOCK_GH_PAGE_SIZE
# (default 100, newest first): without --paginate only the first page is
# returned, with it every page as its own JSON array (like gh).
# MOCK_GH_FAULT=upload-fail:<n> fails the n-th upload;
# MOCK_GH_FAULT=auth fails `gh auth status`.
set -euo pipefail

root="${MOCK_GH_ROOT:?MOCK_GH_ROOT is required}"
mkdir -p "${root}"
printf 'gh %s\n' "$*" >> "${root}/calls.log"

sanitize() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9._-]/_/g'
}

die() {
  echo "$1" >&2
  exit "${2:-1}"
}

repo_flag() {
  local r=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo|-R) r="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "${r}" ]] || die "mock-gh: --repo is required"
  printf '%s' "${r}"
}

releases_dir() {
  printf '%s/releases/%s' "${root}" "$(sanitize "$1")"
}

# find_release <repo> <tag>: prints the release dir
find_release() {
  local d dir
  dir="$(releases_dir "$1")"
  [[ -d "${dir}" ]] || return 1
  for d in "${dir}"/*/; do
    [[ -f "${d}meta.json" ]] || continue
    if [[ "$(jq -r .tag_name "${d}meta.json")" == "$2" ]]; then
      printf '%s' "${d%/}"
      return 0
    fi
  done
  return 1
}

release_json() {
  local d="$1" assets="[]" f sha size digest
  if [[ -d "${d}/assets" ]]; then
    assets="$(
      for f in "${d}"/assets/*; do
        [[ -f "${f}" ]] || continue
        sha="$(sha256sum "${f}" | awk '{print $1}')"
        size="$(wc -c < "${f}" | tr -d ' ')"
        if [[ "${MOCK_GH_NO_DIGEST:-}" == "1" ]]; then digest="null"; else digest="\"sha256:${sha}\""; fi
        printf '{"name":"%s","size":%s,"digest":%s}\n' "$(basename "${f}")" "${size}" "${digest}"
      done | jq -s 'sort_by(.name)'
    )"
  fi
  jq -c --argjson assets "${assets}" '. + {assets: $assets}' "${d}/meta.json"
}

api() {
  local endpoint="" jq_expr="" out f r paginate=false size
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq|-q) jq_expr="$2"; shift 2 ;;
      -H|--header|-X|--method) shift 2 ;;
      --paginate) paginate=true; shift ;;
      *) endpoint="$1"; shift ;;
    esac
  done
  endpoint="${endpoint#/}"
  if [[ "${endpoint}" =~ ^repos/([^/]+/[^/]+)/releases\?per_page=100$ ]]; then
    r="${BASH_REMATCH[1]}"
    size="${MOCK_GH_PAGE_SIZE:-100}"
    out="$(
      for d in "$(releases_dir "${r}")"/*/; do
        [[ -f "${d}meta.json" ]] || continue
        release_json "${d%/}"
      done | jq -s 'sort_by(.id) | reverse'
    )"
    out="$(printf '%s' "${out}" | jq -c --argjson n "${size}" --argjson all "${paginate}" '
      [range(0; ([length, 1] | max); $n) as $i | .[$i:$i + $n]]
      | if $all then .[] else .[0] end')"
  elif [[ "${endpoint}" =~ ^repos/([^/]+/[^/]+)/releases/latest$ ]]; then
    r="${BASH_REMATCH[1]}"
    f="${root}/latest/$(sanitize "${r}")"
    [[ -f "${f}" ]] || die "HTTP 404: Not Found (https://api.github.com/${endpoint})"
    d="$(releases_dir "${r}")/$(cat "${f}")"
    [[ -f "${d}/meta.json" ]] || die "HTTP 404: Not Found (https://api.github.com/${endpoint})"
    out="$(release_json "${d}")"
  else
    f="${root}/api/$(sanitize "${endpoint}")"
    [[ -f "${f}" ]] || die "HTTP 404: Not Found (https://api.github.com/${endpoint})"
    out="$(cat "${f}")"
  fi
  if [[ -n "${jq_expr}" ]]; then
    printf '%s' "${out}" | jq -r "${jq_expr}"
  else
    printf '%s\n' "${out}"
  fi
}

run_download() {
  local run="$1" name="" dir="."
  shift
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name|-n) name="$2"; shift 2 ;;
      --dir|-D) dir="$2"; shift 2 ;;
      --repo|-R) shift 2 ;;
      *) shift ;;
    esac
  done
  local src="${root}/artifacts/${run}/${name}"
  [[ -d "${src}" ]] || die "no valid artifacts found to download"
  mkdir -p "${dir}"
  cp -p "${src}"/* "${dir}/"
}

release_cmd() {
  local sub="$1" r tag d id
  shift
  r="$(repo_flag "$@")"
  case "${sub}" in
    create)
      tag="$1"
      shift
      if find_release "${r}" "${tag}" >/dev/null; then
        die "a release with the same tag name already exists: ${tag}"
      fi
      local draft=false title="${tag}" notes="" verify=false
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --draft) draft=true; shift ;;
          --draft=*) draft="${1#--draft=}"; shift ;;
          --verify-tag) verify=true; shift ;;
          --title|-t) title="$2"; shift 2 ;;
          --notes-file|-F) notes="$(cat "$2")"; shift 2 ;;
          --repo|-R) shift 2 ;;
          *) shift ;;
        esac
      done
      if [[ "${verify}" == "true" && -f "${root}/remotes/$(sanitize "${r}")" ]]; then
        git --git-dir="$(cat "${root}/remotes/$(sanitize "${r}")")" rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
          || die "tag ${tag} doesn't exist in the repo ${r}, aborting due to --verify-tag flag"
      fi
      mkdir -p "$(releases_dir "${r}")"
      id=$(( $(cat "${root}/next-id" 2>/dev/null || echo 100) + 1 ))
      printf '%s\n' "${id}" > "${root}/next-id"
      d="$(releases_dir "${r}")/${id}"
      mkdir -p "${d}/assets"
      jq -n --argjson id "${id}" --arg tag "${tag}" --argjson draft "${draft}" --arg title "${title}" --arg notes "${notes}" \
        '{id: $id, tag_name: $tag, name: $title, draft: $draft, body: $notes}' > "${d}/meta.json"
      printf 'https://github.com/%s/releases/tag/%s\n' "${r}" "${tag}"
      ;;
    upload)
      tag="$1"
      shift
      d="$(find_release "${r}" "${tag}")" || die "release not found"
      local f n count
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --repo|-R) shift 2 ;;
          --clobber) shift ;;
          *)
            f="$1"
            shift
            count=$(( $(cat "${root}/upload-count" 2>/dev/null || echo 0) + 1 ))
            printf '%s\n' "${count}" > "${root}/upload-count"
            if [[ "${MOCK_GH_FAULT:-}" == "upload-fail:${count}" ]]; then
              die "HTTP 502: upload failed for $(basename "${f}")"
            fi
            n="$(basename "${f}")"
            [[ ! -e "${d}/assets/${n}" ]] || die "asset under the same name already exists: [${n}]"
            cp "${f}" "${d}/assets/${n}"
            ;;
        esac
      done
      ;;
    delete-asset)
      tag="$1"
      local name="$2"
      d="$(find_release "${r}" "${tag}")" || die "release not found"
      [[ -f "${d}/assets/${name}" ]] || die "asset ${name} not found in release ${tag}"
      rm -f "${d}/assets/${name}"
      ;;
    edit)
      tag="$1"
      shift
      d="$(find_release "${r}" "${tag}")" || die "release not found"
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --draft=*)
            jq --argjson v "${1#--draft=}" '.draft = $v' "${d}/meta.json" > "${d}/meta.tmp" && mv "${d}/meta.tmp" "${d}/meta.json"
            shift
            ;;
          --latest=true|--latest)
            mkdir -p "${root}/latest"
            basename "${d}" > "${root}/latest/$(sanitize "${r}")"
            shift
            ;;
          --latest=false) shift ;;
          --repo|-R) shift 2 ;;
          *) shift ;;
        esac
      done
      ;;
    download)
      tag="$1"
      shift
      local pattern="" dir="."
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --pattern|-p) pattern="$2"; shift 2 ;;
          --dir|-D) dir="$2"; shift 2 ;;
          --repo|-R) shift 2 ;;
          *) shift ;;
        esac
      done
      d="$(find_release "${r}" "${tag}")" || die "release not found"
      [[ -f "${d}/assets/${pattern}" ]] || die "no assets match the file pattern"
      mkdir -p "${dir}"
      cp "${d}/assets/${pattern}" "${dir}/"
      ;;
    *)
      die "mock-gh: unsupported release subcommand ${sub}"
      ;;
  esac
}

case "${1:-}" in
  api)
    shift
    api "$@"
    ;;
  auth)
    [[ "${2:-}" == "status" ]] || die "mock-gh: unsupported auth subcommand"
    [[ "${MOCK_GH_FAULT:-}" != "auth" ]] || die "You are not logged into any GitHub hosts."
    echo "Logged in to github.com as mock-user" >&2
    ;;
  run)
    [[ "${2:-}" == "download" ]] || die "mock-gh: unsupported run subcommand"
    shift 2
    run_download "$@"
    ;;
  release)
    shift
    sub="${1:-}"
    shift || true
    release_cmd "${sub}" "$@"
    ;;
  workflow)
    [[ "${2:-}" == "run" ]] || die "mock-gh: unsupported workflow subcommand"
    echo "Created workflow_dispatch event for ${3:-}" >&2
    ;;
  *)
    die "mock-gh: unsupported command: $*"
    ;;
esac
