# Adopting release-flow

`release-flow` provides a reusable, language-agnostic release candidate preparation and verification pipeline. The pipeline is the product; the Rust binary in this repository is merely a reference application.

This document describes how to adopt `release-flow` in any project, regardless of programming language or build system.

---

## 1. Quick start: what to copy into your repository

Copy the following files into your project:

1. **`.release-flow.json`** (at your repository root).
2. **`scripts/release-prepare.sh`** — isolated candidate preparation.
3. **`scripts/candidate-guard.sh`** — CI identity and trailer guard.
4. **`scripts/candidate-manifest.sh`** — candidate manifest and SHA256SUMS generator.
5. **`scripts/verify-candidate.sh`** — independent artifact inventory and checksum verifier.
6. **`.github/workflows/candidate.yml`** — the GitHub Actions candidate pipeline.
7. An **adapter script** implementing the Adapter Protocol v1 (e.g. `scripts/adapters/cargo.sh` or a custom script).

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

### Preparing a Candidate

```bash
# Production candidate based on develop:
just release-prepare patch
just release-prepare minor
just release-prepare major

# Test-only candidate based on sandbox (with automatic push to CI):
just release-prepare patch --mode test-only --push
```

The candidate preparation script:
1. Verifies the working tree is clean.
2. Checks for tag collisions (`X.Y.Z` or `vX.Y.Z`) locally and remotely.
3. Creates a detached worktree under `.git/release-flow/worktrees/`.
4. Runs the adapter's `set-version` inside the worktree.
5. Creates an exact candidate commit with Git release trailers.
6. Creates the `release/*` branch (create-only).
7. Cleans up the temporary worktree automatically.

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
