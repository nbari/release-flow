#!/usr/bin/env bash
# release-flow bundle installer (shipped as install.sh at the bundle root).
#
#   install.sh --target <repo-root> [--upgrade] [--with-cargo-adapter]
#   install.sh --target <repo-root> --check
#
# Copies the bundle payload into a Git work tree. Create-only by default; never
# overwrites files you changed; records what it installed in
# .release-flow-bundle.json. Never edits the root justfile or .release-flow.json
# and never runs Git write commands.
#
# Exit codes: 0 ok, 1 conflict/drift/checksum mismatch, 2 usage error or the
# target is not a Git work-tree root.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage: install.sh --target <repo-root> [--upgrade] [--with-cargo-adapter] [--check]
EOF
  exit 2
}

target=""
upgrade=false
with_cargo=false
check=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      [[ $# -ge 2 ]] || usage
      target="$2"
      shift 2
      ;;
    --upgrade) upgrade=true; shift ;;
    --with-cargo-adapter) with_cargo=true; shift ;;
    --check) check=true; shift ;;
    *) usage ;;
  esac
done
[[ -n "${target}" ]] || usage
if [[ "${check}" == "true" && ( "${upgrade}" == "true" || "${with_cargo}" == "true" ) ]]; then
  echo "--check cannot be combined with --upgrade or --with-cargo-adapter" >&2
  usage
fi

bundle_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="${bundle_root}/BUNDLE.json"
if [[ ! -f "${manifest}" ]]; then
  echo "BUNDLE.json not found next to install.sh: run install.sh from an extracted bundle" >&2
  exit 2
fi

for tool in git jq awk; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required tool: ${tool}" >&2
    exit 1
  fi
done
if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
else
  echo "Missing required tool: sha256sum or shasum" >&2
  exit 1
fi

if [[ ! -d "${target}" ]]; then
  echo "Target is not a directory: ${target}" >&2
  exit 2
fi
target_abs="$(cd "${target}" && pwd -P)"
top="$(git -C "${target_abs}" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${top}" || "$(cd "${top}" && pwd -P)" != "${target_abs}" ]]; then
  echo "Target is not the root of a Git work tree: ${target}" >&2
  exit 2
fi

# Every file row must be well-formed: a malformed row would otherwise be skipped
# silently or installed with a bogus mode.
if ! jq -e '
  .schema_version == 1
  and (.payload | type) == "array"
  and (.optional | type) == "array"
  and ((.support // []) | type) == "array"
  and all((.payload + .optional + (.support // []))[];
    type == "object"
    and (.path | type) == "string"
    and (.sha256 | type) == "string"
    and (.mode == "644" or .mode == "755"))' "${manifest}" >/dev/null 2>&1; then
  echo "Unsupported or invalid BUNDLE.json: ${manifest}" >&2
  exit 1
fi
bundle_version="$(jq -r '.bundle_version // empty' "${manifest}")"
source_commit="$(jq -r '.source_commit // empty' "${manifest}")"
workflow_mode="$(jq -r '.workflow_mode // "vendored"' "${manifest}")"
[[ "${source_commit}" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid bundle source_commit' >&2; exit 1; }
case "${workflow_mode}" in vendored|reusable) ;; *) echo 'Invalid bundle workflow_mode' >&2; exit 1 ;; esac

# rows <file> <array-key>: "path<TAB>sha256<TAB>mode" per entry.
rows() {
  jq -r --arg k "$2" '(.[$k] // [])[] | .path + "\t" + .sha256 + "\t" + .mode' "$1"
}

valid_path() {
  case "$1" in
    ''|/*|..|../*|*/..|*/../*|*//*) return 1 ;;
  esac
  [[ "$1" =~ ^[A-Za-z0-9._/-]+$ ]]
}

is_exec_mode_ok() {
  # Compares the executable bit of $1 against the recorded mode $2.
  if [[ "$2" == "755" ]]; then [[ -x "$1" ]]; else [[ ! -x "$1" ]]; fi
}

# unsafe_ancestor <rel-path>: prints the first ancestor of <rel-path> under the
# target that is a symlink or not a directory, so nothing is ever written,
# read or deleted through a redirected parent. Fails when every ancestor is safe.
unsafe_ancestor() {
  local rest acc=""
  [[ "$1" == */* ]] || return 1
  rest="${1%/*}/"
  while [[ -n "${rest}" ]]; do
    acc+="${rest%%/*}"
    rest="${rest#*/}"
    if [[ -L "${target_abs}/${acc}" || ( -e "${target_abs}/${acc}" && ! -d "${target_abs}/${acc}" ) ]]; then
      printf '%s' "${acc}"
      return 0
    fi
    acc+="/"
  done
  return 1
}

# ---------------------------------------------------------------------------
# 1. Verify the bundle itself
# ---------------------------------------------------------------------------
bundle_bad=0
for section in payload optional support; do
  case "${section}" in
    payload) prefix="payload/" ;;
    optional) prefix="optional/" ;;
    *) prefix="" ;;
  esac
  while IFS=$'\t' read -r p s m; do
    [[ -n "${p}" ]] || continue
    if ! valid_path "${p}"; then
      echo "checksum mismatch: invalid path in BUNDLE.json: ${p}" >&2
      bundle_bad=1
      continue
    fi
    f="${bundle_root}/${prefix}${p}"
    if [[ ! -f "${f}" ]]; then
      echo "checksum mismatch: ${prefix}${p} is missing from the bundle" >&2
      bundle_bad=1
    elif [[ "$(sha256_of "${f}")" != "${s}" ]]; then
      echo "checksum mismatch: ${prefix}${p}" >&2
      bundle_bad=1
    fi
  done <<< "$(rows "${manifest}" "${section}")"
done
if (( bundle_bad )); then
  echo "Bundle verification failed; nothing was written." >&2
  exit 1
fi

lock_file="${target_abs}/.release-flow-bundle.json"
if [[ -L "${lock_file}" || ( -e "${lock_file}" && ! -f "${lock_file}" ) ]]; then
  echo "conflict: .release-flow-bundle.json: exists and is not a regular file" >&2
  echo "1 conflict(s); nothing was written." >&2
  exit 1
fi
lock_version=""
lock_tsv=""
if [[ -f "${lock_file}" ]]; then
  if ! jq -e '.schema_version == 1 and (.files | type) == "array"' "${lock_file}" >/dev/null 2>&1; then
    echo "Invalid lock file: ${lock_file}" >&2
    exit 1
  fi
  lock_version="$(jq -r '.bundle_version // empty' "${lock_file}")"
  lock_tsv="$(rows "${lock_file}" files)"
  while IFS=$'\t' read -r p s m; do
    [[ -n "${p}" ]] || continue
    if ! valid_path "${p}"; then
      echo "Invalid path in lock file ${lock_file}: ${p}" >&2
      exit 1
    fi
  done <<< "${lock_tsv}"
fi

lock_sha() {
  printf '%s\n' "${lock_tsv}" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'
}

# ---------------------------------------------------------------------------
# --check: read-only drift report against the lock
# ---------------------------------------------------------------------------
if [[ "${check}" == "true" ]]; then
  if [[ ! -f "${lock_file}" ]]; then
    echo "No release-flow bundle installed in ${target_abs} (missing .release-flow-bundle.json)" >&2
    exit 1
  fi
  checked=0
  drift=0
  while IFS=$'\t' read -r p s m; do
    [[ -n "${p}" ]] || continue
    checked=$(( checked + 1 ))
    f="${target_abs}/${p}"
    if anc="$(unsafe_ancestor "${p}")"; then
      echo "drift: ${p} (parent ${anc} is a symlink or not a directory)" >&2
      drift=$(( drift + 1 ))
    elif [[ -L "${f}" ]]; then
      echo "drift: ${p} (symlink)" >&2
      drift=$(( drift + 1 ))
    elif [[ ! -f "${f}" ]]; then
      echo "drift: ${p} (missing)" >&2
      drift=$(( drift + 1 ))
    elif [[ "$(sha256_of "${f}")" != "${s}" ]]; then
      echo "drift: ${p} (modified)" >&2
      drift=$(( drift + 1 ))
    elif ! is_exec_mode_ok "${f}" "${m}"; then
      echo "drift: ${p} (mode, expected ${m})" >&2
      drift=$(( drift + 1 ))
    fi
  done <<< "${lock_tsv}"
  if [[ "${lock_version}" != "${bundle_version}" ]]; then
    echo "Note: installed bundle ${lock_version} differs from this bundle ${bundle_version}" >&2
  fi
  printf 'bundle_version=%s\nchecked=%d\ndrift=%d\n' "${lock_version}" "${checked}" "${drift}"
  (( drift == 0 )) || exit 1
  exit 0
fi

if [[ -n "${lock_version}" && "${lock_version}" != "${bundle_version}" && "${upgrade}" != "true" ]]; then
  echo "release-flow bundle already installed ${lock_version}; use --upgrade to install ${bundle_version}" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Plan every file before writing any
# ---------------------------------------------------------------------------
# Selected rows: "path<TAB>sha256<TAB>mode<TAB>source"
selected=""
while IFS=$'\t' read -r p s m; do
  [[ -n "${p}" ]] || continue
  selected+="${p}"$'\t'"${s}"$'\t'"${m}"$'\t'"${bundle_root}/payload/${p}"$'\n'
done <<< "$(rows "${manifest}" payload)"
while IFS=$'\t' read -r p s m; do
  [[ -n "${p}" ]] || continue
  # Optional files stay selected once installed, so --upgrade never drops them.
  if [[ "${with_cargo}" == "true" || -n "$(lock_sha "${p}")" ]]; then
    selected+="${p}"$'\t'"${s}"$'\t'"${m}"$'\t'"${bundle_root}/optional/${p}"$'\n'
  fi
done <<< "$(rows "${manifest}" optional)"

plan_action=()
plan_path=()
plan_src=()
plan_mode=()
conflicts=()

add_plan() {
  plan_action+=("$1")
  plan_path+=("$2")
  plan_src+=("$3")
  plan_mode+=("$4")
}

while IFS=$'\t' read -r p s m src; do
  [[ -n "${p}" ]] || continue
  dst="${target_abs}/${p}"
  if anc="$(unsafe_ancestor "${p}")"; then
    conflicts+=("${p}: parent ${anc} is a symlink or not a directory")
    continue
  fi
  if [[ -L "${dst}" || ( -e "${dst}" && ! -f "${dst}" ) ]]; then
    conflicts+=("${p}: exists and is not a regular file")
    continue
  fi
  if [[ ! -e "${dst}" ]]; then
    add_plan install "${p}" "${src}" "${m}"
    continue
  fi
  cur="$(sha256_of "${dst}")"
  if [[ "${cur}" == "${s}" ]]; then
    if is_exec_mode_ok "${dst}" "${m}"; then
      add_plan unchanged "${p}" "${src}" "${m}"
    else
      add_plan chmod "${p}" "${src}" "${m}"
    fi
    continue
  fi
  locked="$(lock_sha "${p}")"
  if [[ -z "${locked}" ]]; then
    conflicts+=("${p}: exists with different content and is not managed by a release-flow bundle")
  elif [[ "${cur}" != "${locked}" ]]; then
    conflicts+=("${p}: modified locally since bundle ${lock_version} was installed")
  elif [[ "${upgrade}" != "true" ]]; then
    conflicts+=("${p}: differs from bundle ${bundle_version}; use --upgrade")
  else
    add_plan update "${p}" "${src}" "${m}"
  fi
done <<< "${selected}"

while IFS=$'\t' read -r p s m; do
  [[ -n "${p}" ]] || continue
  if printf '%s' "${selected}" | awk -F'\t' -v p="${p}" '$1 == p { found = 1 } END { exit !found }'; then
    continue
  fi
  dst="${target_abs}/${p}"
  if anc="$(unsafe_ancestor "${p}")"; then
    conflicts+=("${p}: parent ${anc} is a symlink or not a directory")
    continue
  fi
  [[ -e "${dst}" || -L "${dst}" ]] || continue
  if [[ -f "${dst}" && ! -L "${dst}" && "$(sha256_of "${dst}")" == "${s}" ]]; then
    add_plan remove "${p}" "" ""
  else
    conflicts+=("${p}: no longer shipped by bundle ${bundle_version} but modified locally")
  fi
done <<< "${lock_tsv}"

if (( ${#conflicts[@]} > 0 )); then
  for c in "${conflicts[@]}"; do
    echo "conflict: ${c}" >&2
  done
  echo "${#conflicts[@]} conflict(s); nothing was written." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Apply the plan and write the lock
# ---------------------------------------------------------------------------
installed=0
updated=0
unchanged=0
removed=0
write_tmp=""
trap '[[ -z "${write_tmp}" ]] || rm -f "${write_tmp}"' EXIT
n=${#plan_action[@]}
i=0
while (( i < n )); do
  action="${plan_action[$i]}"
  dst="${target_abs}/${plan_path[$i]}"
  case "${action}" in
    install|update)
      mkdir -p "$(dirname "${dst}")"
      write_tmp="$(mktemp "${dst}.release-flow-tmp.XXXXXX")"
      cp "${plan_src[$i]}" "${write_tmp}"
      chmod "0${plan_mode[$i]}" "${write_tmp}"
      mv -f "${write_tmp}" "${dst}"
      write_tmp=""
      if [[ "${action}" == "install" ]]; then installed=$(( installed + 1 )); else updated=$(( updated + 1 )); fi
      ;;
    chmod)
      chmod "0${plan_mode[$i]}" "${dst}"
      updated=$(( updated + 1 ))
      ;;
    unchanged)
      unchanged=$(( unchanged + 1 ))
      ;;
    remove)
      rm -f "${dst}"
      removed=$(( removed + 1 ))
      ;;
  esac
  i=$(( i + 1 ))
done

files_json="$(printf '%s' "${selected}" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {path: .[0], sha256: .[1], mode: .[2]}) | sort_by(.path)')"
write_tmp="$(mktemp "${lock_file}.tmp.XXXXXX")"
jq -n \
  --arg version "${bundle_version}" \
  --arg commit "${source_commit}" \
  --argjson files "${files_json}" \
  '{schema_version: 1, bundle_version: $version, source_commit: $commit, files: $files}' > "${write_tmp}"
mv -f "${write_tmp}" "${lock_file}"
write_tmp=""

printf 'bundle_version=%s\ninstalled=%d\nupdated=%d\nunchanged=%d\nremoved=%d\n' \
  "${bundle_version}" "${installed}" "${updated}" "${unchanged}" "${removed}"

# ---------------------------------------------------------------------------
# 4. Next steps
# ---------------------------------------------------------------------------
import_line="import '.justfiles/deploy.just'"
has_import=false
for jf in justfile .justfile Justfile; do
  if [[ -f "${target_abs}/${jf}" ]] && grep -Fxq "${import_line}" "${target_abs}/${jf}"; then
    has_import=true
  fi
done
echo "release-flow bundle ${bundle_version} installed into ${target_abs}" >&2
if [[ "${workflow_mode}" == reusable ]]; then
  echo "Workflows are pinned to nbari/release-flow@${source_commit}." >&2
  echo "Set .release-flow.json pipeline.repository=nbari/release-flow, pipeline.sha=${source_commit} and promotion.required_job='candidate / Candidate OK'." >&2
  echo 'Commit configuration and workflow pin upgrades together before preparing a candidate.' >&2
fi
if [[ "${has_import}" != "true" ]]; then
  echo "Next: add this line to the top of your root justfile (.justfile):" >&2
  echo "  ${import_line}" >&2
  echo "  Remove any existing deploy, deploy-minor or deploy-major recipes first." >&2
fi
if [[ ! -f "${target_abs}/.release-flow.json" ]]; then
  echo "Next: create .release-flow.json from the example and set project/adapter:" >&2
  echo "  cp '${bundle_root}/docs/release-flow.example.json' '${target_abs}/.release-flow.json'" >&2
fi
echo "Review and commit the installed files (including .release-flow-bundle.json)." >&2
