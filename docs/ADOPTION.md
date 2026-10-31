# Adopting release-flow

`release-flow` provides a reusable, language-agnostic release candidate preparation and verification pipeline. The pipeline is the product; the Rust binary in this repository is merely a reference application.

This document describes how to adopt `release-flow` in any project, regardless of programming language or build system.

---

## 1. Quick start: install with the versioned bundle

release-flow ships as `release-flow-bundle-<V>.tar.gz`. Every validated release-flow candidate includes it as an artifact, and you can build it from a checkout of this repository (GNU tar required):

```bash
bash scripts/release-flow-bundle.sh --version <V> --out dist
```

Install it into your repository (run from your repository root):

```bash
tar -xzf release-flow-bundle-<V>.tar.gz
bash release-flow-bundle-<V>/install.sh --target .                       # add --with-cargo-adapter for Rust projects
```

Then:

1. Add the import as the first line of your root justfile (`.justfile`, `justfile` or `Justfile`):

   ```just
   import '.justfiles/deploy.just'
   ```

2. Create `.release-flow.json` (§2), e.g. `cp release-flow-bundle-<V>/docs/release-flow.example.json .release-flow.json`, and point `adapter` at your project adapter (§3).
3. Review and commit the installed files, including `.release-flow-bundle.json`, then push them to both base branches.

The installer copies these files into your repository:

| Path | Purpose |
|---|---|
| `.justfiles/deploy.just` | `just deploy`, `deploy-minor`, `deploy-major` |
| `scripts/release-deploy.sh` | Branch-aware deploy orchestrator |
| `scripts/release-prepare.sh` | Isolated candidate preparation |
| `scripts/candidate-guard.sh` | CI identity and trailer guard |
| `scripts/candidate-manifest.sh` | Candidate manifest and `SHA256SUMS` generator |
| `scripts/verify-candidate.sh` | Independent artifact inventory and checksum verifier |
| `.github/workflows/candidate.yml` | GitHub Actions candidate pipeline |
| `scripts/adapters/cargo.sh` | Cargo reference adapter (only with `--with-cargo-adapter`) |

The installer verifies every bundle file against `BUNDLE.json` first, plans every change before writing anything, and refuses to overwrite files it did not install or that you modified. It rejects symlinked destinations, symlinked parent directories, and non-regular lock files as conflicts. It never edits your justfile or `.release-flow.json` and never runs Git write commands. Exit codes: `0` ok, `1` conflict/drift/checksum mismatch, `2` usage error or the target is not a Git work-tree root.

### Upgrading and checking for drift

```bash
bash release-flow-bundle-<V2>/install.sh --target . --upgrade   # replace files you have not modified
bash release-flow-bundle-<V>/install.sh --target . --check      # read-only: compare installed files with the lock
```

`--upgrade` overwrites only files whose content still matches `.release-flow-bundle.json`, and deletes files the new bundle no longer ships only if they are unmodified. Any locally modified file is reported as a conflict and nothing is written. Without `--upgrade`, installing a different version exits `1` with `already installed <v>; use --upgrade`.

### Manual installation (fallback)

Without the bundle, copy the files in the table above from this repository, plus `.release-flow.json` and an adapter script implementing the Adapter Protocol v1 (§3). You then have to track upgrades yourself.

---

## 2. Configuration: `.release-flow.json`

Place `.release-flow.json` at your repository root:

```json
{
  "schema_version": 1,
  "project": "my-service",
  "adapter": "scripts/adapters/custom.sh",
  "remote": "origin",
  "production_base": "develop",
  "test_base": "sandbox"
}
```

| Key | Description |
|---|---|
| `schema_version` | Must be `1`. |
| `project` | Project identifier (alphanumeric, dots, hyphens, underscores). |
| `adapter` | Relative path to the executable adapter script in your repository. |
| `remote` | Git remote name (default: `origin`). |
| `production_base` | The integration branch for production releases (default: `develop`). |
| `test_base` | The branch used for test-only candidate verification (default: `sandbox`). |

---

## 3. Project Adapter Protocol (v1)

Release automation communicates with your project through a single executable adapter specified in `.release-flow.json`.

- The adapter is executed directly with its shebang (it can be written in Bash, Python, or any executable binary).
- Working directory (`cwd`) is always the project root (either the repository checkout or an isolated worktree).
- Exit codes:
  - `0`: Success.
  - `1`: Operation failed.
  - `2`: Usage error or unknown subcommand.

### Adapter Interface

| Subcommand | Input Arguments | Output (`stdout`) | Side Effects |
|---|---|---|---|
| `version` | None | Current version string (`X.Y.Z`) | None (read-only) |
| `set-version <X.Y.Z>` | Target SemVer version | Relative paths of modified files, one per line | Updates version metadata in project manifests |
| `verify` | None | Free-form test/lint output | Runs test suite, formatting, and linters |
| `inventory <X.Y.Z>` | Release version | JSON inventory string | None (read-only) |
| `package <X.Y.Z> <outdir>` | Release version, output directory (`SOURCE_DATE_EPOCH` in env) | Free-form build logs | Builds and writes artifacts into `<outdir>` |

### Inventory JSON Schema

```json
{
  "artifacts": [
    {
      "name": "my-service-1.2.0-linux-amd64.tar.gz",
      "target": "linux-amd64"
    }
  ],
  "build_info": {
    "tools": {
      "compiler": "go1.23.2",
      "os": "linux"
    }
  }
}
```

### Packaging Requirements
- Artifact names must match `^[A-Za-z0-9][A-Za-z0-9._+-]*$` and cannot be `manifest.json` or `SHA256SUMS`.
- `SOURCE_DATE_EPOCH` must be respected for reproducible archives (e.g. using `tar --mtime="@${SOURCE_DATE_EPOCH}"` and `gzip -n`).
- The adapter must refuse to package if the output directory is non-empty.

---

## 4. Minimal Custom Adapter Example (e.g., Python / Generic)

Here is a simple adapter for a project whose version is maintained in a `VERSION` file:

```bash
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "${cmd}" in
  version)
    head -n 1 VERSION | tr -d '\r\n '
    ;;
  set-version)
    target="$1"
    printf '%s\n' "${target}" > VERSION
    echo "VERSION"
    ;;
  verify)
    pytest
    flake8
    ;;
  inventory)
    ver="$1"
    cat <<EOF
{
  "artifacts": [
    { "name": "my-app-${ver}.tar.gz", "target": "any" }
  ],
  "build_info": { "tools": { "python": "$(python3 --version)" } }
}
EOF
    ;;
  package)
    ver="$1"
    outdir="$2"
    mkdir -p "${outdir}"
    tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 \
      -czf "${outdir}/my-app-${ver}.tar.gz" app/
    ;;
  *)
    exit 2
    ;;
esac
```

---

## 5. Candidate Lifecycle & Branch Namespaces

Release candidates are created in **isolated Git worktrees** without altering your active checkout or integration branches.

| Mode | Base Branch | Candidate Branch | Production Promotable? |
|---|---|---|---|
| `production` | `develop` (default) | `release/<version>-<base12>` | **Yes** (in Milestone 2) |
| `test-only` | `sandbox` (default) | `release/test/<version>-<base12>` | **Never** (rejected by design) |

### Deploy module: `just deploy`

`.justfiles/deploy.just` adds three top-level recipes to the importing justfile:

```bash
just deploy         # patch
just deploy-minor   # minor
just deploy-major   # major
```

The branch you are on selects the policy; there is no `--mode` flag:

| Current branch | Result |
|---|---|
| `test_base` | Test-only candidate `release/test/X.Y.Z-<base12>` (never promotable) |
| `production_base` | Production candidate `release/X.Y.Z-<base12>` |
| `main` | Rejected: `main` only receives guarded release promotion |
| `release/*` | Rejected: candidates are immutable and never a deploy base |
| Detached HEAD | Rejected: policy is selected by branch |
| Any other branch | Rejected, naming the allowed branches |

Exit codes (from `scripts/release-deploy.sh`):

| Code | Meaning |
|---|---|
| `0` | Candidate prepared and pushed |
| `1` | Configuration, prerequisite, precondition or preparation failure |
| `2` | Usage error |
| `3` | Branch policy rejection |

Guarantees:

- **Rejections change nothing in Git.** Branch and configuration checks use read-only Git commands only: no fetch, no lock, no files under `.git`.
- **Accepted branches fetch the base and push only a `release/**` branch** (create-only). A failure after the fetch can leave the updated `refs/remotes/<remote>/<base>` and the `.git/release-flow/` directory behind, but never a partial candidate on the remote or a held lock.
- **The commit you are on is the commit released.** Local `HEAD` must equal the freshly fetched remote base: unpushed commits fail with `has unpushed commits`, a branch behind its remote fails with `Base mismatch` (pull, then retry).
- The working tree must be clean, the version tag must not exist, and the candidate branch must not exist locally or on the remote (running `just deploy` twice on the same base gives `Branch collision`).
- No language toolchain is needed by deploy itself; only your adapter's `version` and `set-version` run.

On success, stdout carries `project`, `version`, `mode`, `base_branch`, `base_commit`, `candidate_branch`, `candidate_commit`, `pushed`, `remote` and `ci_url` (a GitHub Actions link when the remote is on github.com, otherwise empty) as `key=value` lines; a human summary goes to stderr. The local candidate branch is kept; delete it with `git branch -D <candidate_branch>` when no longer needed.

**Requirements:** just ≥ 1.27.0, bash (3.2 or newer), git ≥ 2.31, jq.

**Running from subdirectories.** Recipes resolve the scripts relative to the module file and the repository from the root justfile's directory, so `just deploy` works from any nested directory, including ignored nested Git repositories, and regardless of `set working-directory`, `set no-cd`, `set shell`, `set positional-arguments` or `set export` in your justfile. Monorepos with nested justfiles: `just` uses the nearest justfile, so either run from the root or add `set fallback := true` to the nested justfile.

**Recipe name collisions.** Imports share the root justfile's namespace. Delete any existing `deploy`, `deploy-minor` or `deploy-major` recipes (for example legacy recipes that bump, merge into `main` and tag) before adding the import; `just` reports duplicate recipes as an error. If your justfile sets `allow-duplicate-recipes`, your own recipe silently wins over the module, so check `just --show deploy`.

### Low-level preparation

`scripts/release-prepare.sh` remains available for explicit control (it is what `just deploy` calls):

```bash
# Production candidate based on develop (not pushed):
just release-prepare patch

# Test-only candidate based on sandbox, pushed to CI:
just release-prepare patch --mode test-only --push
```

The candidate preparation script:
1. Verifies the working tree is clean.
2. Fetches the base branch and, with `--expect-base-commit <sha>`, requires it to equal that commit.
3. Checks for tag collisions (`X.Y.Z` or `vX.Y.Z`) locally and remotely.
4. Creates a detached worktree under `.git/release-flow/worktrees/`.
5. Runs the adapter's `set-version` inside the worktree.
6. Creates an exact candidate commit with Git release trailers.
7. Creates the `release/*` branch (create-only) and optionally pushes it create-only.
8. Cleans up the temporary worktree and its lock automatically, on success and on failure.

---

## 6. Artifact Manifest & Verification

When a candidate branch is pushed to GitHub, `.github/workflows/candidate.yml` runs:

1. **`guard`**: Validates candidate branch name, commit trailers, single parent, and ancestry.
2. **`test`**: Runs the adapter's `verify` on the exact candidate commit.
3. **`package`**: Invokes the adapter's `package`, writes `SHA256SUMS`, and generates `manifest.json`.
4. **`verify`**: In an isolated job, downloads the artifact bundle and runs `scripts/verify-candidate.sh` with pinned SHA-256.
5. **`report`**: Fails closed if any step failed; publishes a GitHub Step Summary.

### Verifier CLI

```bash
bash scripts/verify-candidate.sh \
  --dir <artifact-directory> \
  --commit <candidate-sha> \
  --version <version> \
  --mode <production|test-only> \
  --manifest-sha256 <pinned-sha256>
```

---

## 7. Current Implementation Status

- **Implemented and Tested:**
  - Branch-aware deploy module (`.justfiles/deploy.just`, `scripts/release-deploy.sh`).
  - Versioned distribution bundle and installer (`scripts/release-flow-bundle.sh`, `scripts/release-flow-install.sh`).
  - Worktree candidate preparation (`scripts/release-prepare.sh`).
  - Adapter protocol v1 and Cargo reference adapter (`scripts/adapters/cargo.sh`).
  - Versioned artifact manifest v1 generation (`scripts/candidate-manifest.sh`).
  - Independent artifact verifier (`scripts/verify-candidate.sh`).
  - GitHub Actions candidate pipeline (`.github/workflows/candidate.yml`).
  - Comprehensive failure-injection suite (`tests/pipeline/`).
- **Planned (Milestone 2):**
  - Guarded atomic Git promotion (`main`, `develop`, and annotated signed tag via single atomic push).
  - GitHub Rulesets configuration.
- **Planned (Milestone 3):**
  - Independent, idempotent publishers (GitHub Releases, OCI, Docs, Helm).
