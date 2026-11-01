# shellcheck shell=bash
# Filesystem storage backend (file:///abs/root). Sourced by storage.sh.
#
# Create-only writes use link(2): `ln tmp dst` fails atomically when dst
# exists. Temporary files and CAS locks are dot-prefixed, so they are never
# valid keys and never listed. bash 3.2 compatible.

BE_ROOT=""

be_init() {
  local uri="$1"
  BE_ROOT="${uri#file://}"
  if [[ "${BE_ROOT}" != /* ]]; then
    echo "storage: file URI must hold an absolute path: ${uri}" >&2
    return 1
  fi
  BE_ROOT="${BE_ROOT%/}"
  [[ -n "${BE_ROOT}" ]] || { echo "storage: refusing the filesystem root as a store" >&2; return 1; }
  if ! mkdir -p "${BE_ROOT}" 2>/dev/null || [[ ! -d "${BE_ROOT}" ]]; then
    echo "storage: cannot create store directory ${BE_ROOT}" >&2
    return 1
  fi
}

be_token_of() {
  rf_sha256_file "$1"
}

be_head() {
  local f="${BE_ROOT}/$1"
  [[ -f "${f}" ]] || return 4
  be_token_of "${f}"
}

be_get() {
  local f="${BE_ROOT}/$1"
  [[ -f "${f}" ]] || return 4
  cp "${f}" "$2"
}

be_put_create() {
  local key="$1" src="$2" dst dir tmp
  dst="${BE_ROOT}/${key}"
  dir="$(dirname "${dst}")"
  mkdir -p "${dir}" || return 1
  tmp="${dir}/.$(basename "${dst}").tmp.$$.${RANDOM}"
  cp "${src}" "${tmp}" || { rm -f "${tmp}"; return 1; }
  if ln "${tmp}" "${dst}" 2>/dev/null; then
    rm -f "${tmp}"
    return 0
  fi
  rm -f "${tmp}"
  [[ -e "${dst}" ]] && return 5
  return 1
}

# cas_lock_stale <lock-dir>: 0 when the lock's owner process is dead or the
# lock is older than 10 s (a crashed or killed writer must not wedge the key).
cas_lock_stale() {
  local lock="$1" pid mtime now
  pid="$(cat "${lock}/pid" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && ! kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi
  mtime="$(stat -c %Y "${lock}" 2>/dev/null || stat -f %m "${lock}" 2>/dev/null || true)"
  [[ "${mtime}" =~ ^[0-9]+$ ]] || return 1
  now="$(date +%s)"
  (( now - mtime > 10 ))
}

# cas_lock_reclaim <lock-dir> <key>: breaks a stale lock. Reclaimers are
# serialized by a guard directory and re-check staleness under it, so a fresh
# lock taken after a previous reclaim is never removed.
cas_lock_reclaim() {
  local lock="$1" key="$2" guard="$1.reclaim" pid
  if ! mkdir "${guard}" 2>/dev/null; then
    # a reclaimer that died mid-reclaim must not wedge the key either
    cas_lock_stale "${guard}" && rm -rf "${guard}"
    return 0
  fi
  if [[ -d "${lock}" ]] && cas_lock_stale "${lock}"; then
    pid="$(cat "${lock}/pid" 2>/dev/null || echo unknown)"
    rm -rf "${lock}"
    echo "storage: reclaimed stale CAS lock for ${key} (owner pid ${pid})" >&2
  fi
  rmdir "${guard}" 2>/dev/null || true
}

# cas_lock_acquire <dst> <key>: takes the per-key CAS lock (prints its path),
# recording this process as the owner.
cas_lock_acquire() {
  local dst="$1" key="$2" lock i=0
  lock="$(dirname "${dst}")/.$(basename "${dst}").cas.lock"
  until mkdir "${lock}" 2>/dev/null; do
    if cas_lock_stale "${lock}"; then
      cas_lock_reclaim "${lock}" "${key}"
    fi
    i=$(( i + 1 ))
    if (( i > 100 )); then
      echo "storage: CAS lock busy for ${key}" >&2
      return 1
    fi
    sleep 0.1
  done
  printf '%s\n' "$$" > "${lock}/pid"
  printf '%s' "${lock}"
}

# be_put_cas <key> <src> <token|absent>
be_put_cas() {
  local key="$1" src="$2" expect="$3" dst dir lock tmp cur rc
  dst="${BE_ROOT}/${key}"
  dir="$(dirname "${dst}")"
  mkdir -p "${dir}" || return 1
  lock="$(cas_lock_acquire "${dst}" "${key}")" || return 1
  if [[ -f "${dst}" ]]; then cur="$(be_token_of "${dst}")"; else cur="absent"; fi
  if [[ "${cur}" != "${expect}" ]]; then
    rc=5
  else
    tmp="${dir}/.$(basename "${dst}").tmp.$$.${RANDOM}"
    if cp "${src}" "${tmp}" && mv "${tmp}" "${dst}"; then rc=0; else rm -f "${tmp}"; rc=1; fi
  fi
  rm -rf "${lock}"
  return "${rc}"
}

be_list() {
  local prefix="$1" start="${BE_ROOT}"
  if [[ "${prefix}" == */* ]]; then
    start="${BE_ROOT}/${prefix%/*}"
  fi
  [[ -d "${start}" ]] || return 0
  find "${start}" -type f 2>/dev/null \
    | sed "s|^${BE_ROOT}/||" \
    | grep -v -e '^\.' -e '/\.' \
    | awk -v p="${prefix}" 'substr($0, 1, length(p)) == p' \
    | LC_ALL=C sort || true
}

# be_delete_if <key> <token>: deletes only while the content still has the
# token, under the same lock as be_put_cas. 0 deleted, 4 missing, 5 changed.
be_delete_if() {
  local key="$1" expect="$2" dst lock rc
  dst="${BE_ROOT}/${key}"
  [[ -f "${dst}" ]] || return 4
  lock="$(cas_lock_acquire "${dst}" "${key}")" || return 1
  if [[ ! -f "${dst}" ]]; then
    rc=4
  elif [[ "$(be_token_of "${dst}")" != "${expect}" ]]; then
    rc=5
  elif rm -f "${dst}"; then
    rc=0
  else
    rc=1
  fi
  rm -rf "${lock}"
  return "${rc}"
}
