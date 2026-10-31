#!/usr/bin/env bash
# Common test harness for release-flow pipeline failure injection tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ROOT

TF_TMP="$(mktemp -d)"
export TF_TMP

cleanup_tmp() {
  rm -rf "${TF_TMP}"
}
trap cleanup_tmp EXIT

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME="Pipeline Tester"
export GIT_AUTHOR_EMAIL="tester@example.com"
export GIT_COMMITTER_NAME="Pipeline Tester"
export GIT_COMMITTER_EMAIL="tester@example.com"
unset GIT_DIR GIT_WORK_TREE GITHUB_ACTIONS
# Outside just settings must not leak into fixture runs.
unset JUST_JUSTFILE JUST_WORKING_DIRECTORY
export LC_ALL=C

T_PASSED=0
T_FAILED=0
T_RC=0
T_OUT=""
T_ERR=""

t_case() {
  printf '  - %s\n' "$1"
}

t_run() {
  set +e
  "$@" > "${TF_TMP}/.out" 2> "${TF_TMP}/.err"
  T_RC=$?
  set -e
  T_OUT="$(cat "${TF_TMP}/.out")"
  T_ERR="$(cat "${TF_TMP}/.err")"
}

t_run_group() {
  set +e
  STUB_ALLOW_GROUP_KILL=1 setsid --wait "$@" > "${TF_TMP}/.out" 2> "${TF_TMP}/.err"
  T_RC=$?
  set -e
  T_OUT="$(cat "${TF_TMP}/.out")"
  T_ERR="$(cat "${TF_TMP}/.err")"
}

assert_rc() {
  local expected="$1" msg="$2"
  if [[ "${expected}" == "nonzero" ]]; then
    if (( T_RC != 0 )); then
      T_PASSED=$(( T_PASSED + 1 ))
    else
      printf '    FAIL: %s (expected non-zero exit, got 0)\n' "${msg}" >&2
      T_FAILED=$(( T_FAILED + 1 ))
    fi
  else
    if (( T_RC == expected )); then
      T_PASSED=$(( T_PASSED + 1 ))
    else
      printf '    FAIL: %s (expected exit %d, got %d)\n      stderr: %s\n' "${msg}" "${expected}" "${T_RC}" "${T_ERR}" >&2
      T_FAILED=$(( T_FAILED + 1 ))
    fi
  fi
}

assert_eq() {
  local expected="$1" actual="$2" msg="$3"
  if [[ "${expected}" == "${actual}" ]]; then
    T_PASSED=$(( T_PASSED + 1 ))
  else
    printf '    FAIL: %s\n      expected: %s\n      actual:   %s\n' "${msg}" "${expected}" "${actual}" >&2
    T_FAILED=$(( T_FAILED + 1 ))
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "${haystack}" == *"${needle}"* ]]; then
    T_PASSED=$(( T_PASSED + 1 ))
  else
    printf '    FAIL: %s (needle not found: %s)\n      haystack: %s\n' "${msg}" "${needle}" "${haystack}" >&2
    T_FAILED=$(( T_FAILED + 1 ))
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if [[ "${haystack}" != *"${needle}"* ]]; then
    T_PASSED=$(( T_PASSED + 1 ))
  else
    printf '    FAIL: %s (unexpected needle found: %s)\n' "${msg}" "${needle}" >&2
    T_FAILED=$(( T_FAILED + 1 ))
  fi
}

t_finish() {
  printf 'Results: %d passed, %d failed\n' "${T_PASSED}" "${T_FAILED}"
  if (( T_FAILED > 0 )); then
    exit 1
  fi
  exit 0
}

# tf_fixture_repo name [version] [setup_fn]
# setup_fn runs inside the clone after the fixture files are written and before
# they are committed on main, so its files reach main, develop and sandbox.
tf_fixture_repo() {
  local name="$1" version="${2:-0.1.0}" setup_fn="${3:-}"
  local bare_dir="${TF_TMP}/${name}.git"
  local clone_dir="${TF_TMP}/${name}"

  git init --bare --quiet "${bare_dir}"

  git clone --quiet "${bare_dir}" "${clone_dir}"
  (
    cd "${clone_dir}"
    git checkout -b main --quiet
    printf '%s\n' "${version}" > VERSION
    mkdir -p tools
    cp "${ROOT}/tests/pipeline/fixtures/stub-adapter.sh" tools/adapter.sh
    chmod +x tools/adapter.sh
    cat <<EOF > .release-flow.json
{
  "schema_version": 1,
  "project": "${name}",
  "adapter": "tools/adapter.sh",
  "remote": "origin",
  "production_base": "develop",
  "test_base": "sandbox"
}
EOF
    if [[ -n "${setup_fn}" ]]; then
      "${setup_fn}" >&2
    fi
    git add .
    git commit -m "Initial commit on main" --quiet
    git push origin main --quiet

    git checkout -b develop --quiet
    printf 'develop changes\n' >> README.md
    git add README.md
    git commit -m "Develop commit" --quiet
    git push origin develop --quiet

    git checkout -b sandbox --quiet
    printf 'sandbox changes\n' >> README.md
    git add README.md
    git commit -m "Sandbox commit" --quiet
    git push -u origin sandbox --quiet
  )

  printf '%s' "${clone_dir}"
}

# Vendors the deploy module and scripts from ${ROOT} into the current fixture
# directory (use as a tf_fixture_repo setup_fn).
tf_vendor_deploy() {
  mkdir -p .justfiles scripts
  cp "${ROOT}/.justfiles/deploy.just" .justfiles/deploy.just
  cp "${ROOT}/scripts/release-deploy.sh" scripts/release-deploy.sh
  cp "${ROOT}/scripts/release-prepare.sh" scripts/release-prepare.sh
  cat <<'EOF' > .justfile
import '.justfiles/deploy.just'

default:
    @echo root-default
EOF
}

# Puts failing cargo/rustc/rustup shims first on PATH; every invocation is
# recorded in ${TF_TMP}/forbidden-tools.log.
tf_forbid_toolchains() {
  local shim_dir="${TF_TMP}/shims" tool
  mkdir -p "${shim_dir}"
  for tool in cargo rustc rustup; do
    cat <<EOF > "${shim_dir}/${tool}"
#!/usr/bin/env bash
printf '%s\n' "${tool}" >> "${TF_TMP}/forbidden-tools.log"
exit 127
EOF
    chmod +x "${shim_dir}/${tool}"
  done
  PATH="${shim_dir}:${PATH}"
  export PATH
}

tf_snapshot() {
  local repo="$1"
  (
    cd "${repo}"
    printf '=== REFS ===\n'
    git for-each-ref --format='%(refname) %(objectname)' | sort
    printf '=== HEAD ===\n'
    git symbolic-ref -q HEAD || git rev-parse HEAD
    printf '=== STATUS ===\n'
    git status --porcelain
    printf '=== STASH ===\n'
    git stash list
    printf '=== FETCH_HEAD ===\n'
    local fetch_head
    fetch_head="$(git rev-parse --path-format=absolute --git-path FETCH_HEAD)"
    if [[ -f "${fetch_head}" ]]; then
      sha256sum "${fetch_head}" | awk '{print $1}'
    else
      printf 'absent\n'
    fi
    printf '=== RELEASE-FLOW DIR ===\n'
    if [[ -e "$(git rev-parse --path-format=absolute --git-common-dir)/release-flow" ]]; then
      printf 'present\n'
    else
      printf 'absent\n'
    fi
    printf '=== WORKTREES ===\n'
    git worktree list --porcelain | grep '^worktree ' | sort
    printf '=== LS-REMOTE ===\n'
    git ls-remote origin | sort
  )
}
