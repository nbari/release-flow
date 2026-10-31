default: test
    @just --list

fmt:
    cargo fmt --all --check

clippy:
    cargo clippy --all-targets --all-features

test: clippy fmt
    cargo test --all-features

# Local gate used by CI. The lockfile is deliberately required.
check:
    cargo fmt --all -- --check
    cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
    cargo test --locked --workspace --all-features
    bash tests/candidate-verification.sh

build:
    cargo build --release --locked

# Inspect the current clone; never modifies the repository.
status:
    cargo run --locked -- status

# Manually dispatch the candidate pipeline on the current branch.
candidate:
    gh workflow run candidate.yml --ref "$(git branch --show-current)"

# Ensure working tree has no uncommitted changes.
check-clean:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "❌ Working tree is dirty. Stash or commit changes first." >&2
        exit 1
    fi

# Squash current disposable branch commits onto base (default: origin/develop) and push.
sandbox-squash message="" base="origin/develop": check-clean
    #!/usr/bin/env bash
    set -euo pipefail

    message="{{ message }}"
    base="{{ base }}"
    current_branch="$(git branch --show-current)"

    if [[ "${current_branch}" == "develop" || "${current_branch}" == "main" ]]; then
        echo "❌ Refusing to rewrite ${current_branch}. Run from a disposable branch." >&2
        exit 1
    fi

    git fetch origin --quiet
    if ! git rev-parse --verify "${base}" >/dev/null 2>&1; then
        echo "❌ Base ref '${base}' not found. Use e.g. base=origin/develop." >&2
        exit 1
    fi

    if ! git merge-base --is-ancestor "${base}" HEAD; then
        echo "❌ '${base}' is not an ancestor of ${current_branch}. Rebase or merge '${base}' first." >&2
        exit 1
    fi

    git reset --soft "${base}"
    git add -A

    if git diff --cached --quiet; then
        echo "❌ No changes to commit after soft reset." >&2
        exit 1
    fi

    change_stats="$(
      git diff --cached --name-status | awk '
      BEGIN {added=0; modified=0; deleted=0;}
      {
        code = substr($1, 1, 1);
        if (code == "A") {
          added++;
        } else if (code == "D") {
          deleted++;
        } else {
          modified++;
        }
      }
      END {
        printf "added: %d, modified: %d, deleted: %d", added, modified, deleted
      }'
    )"
    file_list="$(git diff --cached --name-only | sed 's/^/- /')"
    detail_body="$(printf '%s\n\n%s' "${change_stats}" "${file_list}")"

    if [[ -n "${message}" ]]; then
        git commit -m "${message}" -m "${detail_body}"
    else
        git commit -m "squash $(date +%Y-%m-%d)" -m "${detail_body}"
    fi
    git push --force-with-lease origin HEAD
