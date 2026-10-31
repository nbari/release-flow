# Adopting release-flow

`release-flow` provides a reusable, language-agnostic release pipeline: candidate preparation and verification, guarded atomic promotion, durable artifact storage and independently recoverable publishing. The pipeline is the product; the Rust binary in this repository is merely a reference application.

This document describes how to adopt `release-flow` in any project, regardless of programming language or build system.

---

## 1. Quick start: install with the versioned bundle

release-flow ships as `release-flow-bundle-<V>.tar.gz`. Every validated release-flow candidate includes it as an artifact, and you can build it from a checkout of this repository (GNU tar required):

```bash
bash scripts/release-flow-bundle.sh --version <V> --out dist --workflow-mode reusable
```

Install it into your repository (run from your repository root):

```bash
tar -xzf release-flow-bundle-<V>.tar.gz
bash release-flow-bundle-<V>/install.sh --target .                       # add --with-cargo-adapter for Rust projects
```

The recommended `--workflow-mode reusable` bundle installs thin callers pinned to its clean source commit. It also includes the existing local operations scripts, so your root Justfile needs only the import. The example configuration in this bundle carries the matching `pipeline` pin and `candidate / Candidate OK` job name. Configure your project, repository and adapter in that example. The default `--workflow-mode vendored` keeps the fully vendored/offline installation available; omit `pipeline` in that mode. Never edit managed deploy recipes.

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
| `.justfiles/deploy.just` | `just deploy`, `deploy-minor`, `deploy-major`, `release-promote`, `release-status`, `release-retry` |
| `scripts/release-deploy.sh` | Branch-aware deploy orchestrator |
| `scripts/release-prepare.sh` | Isolated candidate preparation |
| `scripts/candidate-guard.sh` | CI identity and trailer guard |
| `scripts/candidate-targets.sh` | Candidate package matrix from the adapter's `targets` |
| `scripts/candidate-manifest.sh` | Candidate manifest and `SHA256SUMS` generator |
| `scripts/verify-candidate.sh` | Independent artifact inventory and checksum verifier |
| `scripts/release-promote.sh` | Guarded atomic promotion (PF01–PF20, signed tag, one atomic push, reconciliation) |
| `scripts/release-status.sh` | Read-only release and per-channel publication state |
| `scripts/release-retry.sh` | Re-run one publication channel (dispatch or `--local`) |
| `scripts/lib/{common,schema,github,tag}.sh` | Shared helpers, strict JSON schemas, GitHub evidence, signed tag format |
| `scripts/storage/storage.sh`, `storage/backends/{fs,s3}.sh` | Content-addressed, create-only durable storage (`file:///`, `s3://`) |
| `scripts/storage/ci-credentials.sh` | Storage credentials in Actions (OIDC role or static keys) |
| `scripts/publication/{publish,resolve,latest,ledger}.sh` | Publication driver, signed-tag resolver, latest decision, ledger and locks |
| `scripts/publication/ci-install-oras.sh` | Pinned, checksum-verified ORAS for the OCI publisher |
| `scripts/publishers/{github-release,oci,crates-io,docs,helm}.sh` | Channel publishers (`observe` / `apply`) |
| `.github/workflows/candidate.yml` | GitHub Actions candidate pipeline (the only artifact builder) |
| `.github/workflows/release.yml` | One independent publish job per channel (tag push or dispatch) |
| `scripts/pipeline-pin.sh` | Pins release-flow scripts to this workflow's commit (`job.workflow_sha`) and rejects an unpinned or mismatched call |
| `scripts/adapters/cargo.sh` | Cargo reference adapter (only with `--with-cargo-adapter`) |

The bundle also carries the complete shell example, Marketplace guide, caller templates, `docs/RULESETS.md` and `docs/rulesets/*.json` (repository rulesets to apply before the first promotion).

The installer verifies every bundle file against `BUNDLE.json` first, plans every change before writing anything, and refuses to overwrite files it did not install or that you modified. It rejects symlinked destinations, symlinked parent directories, and non-regular lock files as conflicts. It never edits your justfile or `.release-flow.json` and never runs Git write commands. Exit codes: `0` ok, `1` conflict/drift/checksum mismatch, `2` usage error or the target is not a Git work-tree root.

### Upgrading and checking for drift

```bash
bash release-flow-bundle-<V2>/install.sh --target . --upgrade   # replace files you have not modified
bash release-flow-bundle-<V>/install.sh --target . --check      # read-only: compare installed files with the lock
```

`--upgrade` overwrites only files whose content still matches `.release-flow-bundle.json`, and deletes files the new bundle no longer ships only if they are unmodified. Any locally modified file is reported as a conflict and nothing is written. Without `--upgrade`, installing a different version exits `1` with `already installed <v>; use --upgrade`.

### Manual installation (fallback)

Without the bundle, copy the files in the table above from this repository, plus `.release-flow.json` and an adapter script implementing the Adapter Protocol v1 (§3). You then have to track upgrades yourself.

### Reusable workflows at a pinned SHA

Use this when another repository should run release-flow's candidate and publish pipelines by calling this repository at a pinned commit, with centralized orchestration. Local scripts still come from the versioned bundle, preserving the one-import Just interface. Vendored mode remains available for frozen/offline use.

The adopter commits:

1. `.github/workflows/candidate.yml` and `.github/workflows/release.yml`, copied from the templates below with `__RELEASE_FLOW_SHA__` replaced by the full commit SHA. The file names and the job ids `candidate` and `release` are fixed: promotion's default workflow path, `release-retry` dispatching `release.yml`, and crates.io Trusted Publishing all depend on them. Do not set `concurrency` on the caller (it can deadlock with the called workflow's group). Pass only explicitly named storage secrets to candidate and publisher secrets to release, when static credentials are needed. OIDC needs no inherited secrets.
2. `.release-flow.json` with the same pin, plus the reusable job name:

```json
{
  "pipeline": { "repository": "nbari/release-flow", "sha": "<40 lowercase hex>" },
  "promotion": { "required_job": "candidate / Candidate OK" }
}
```

3. The project's own adapter, as today.
4. Repository settings in the adopter's repo: an Actions policy that allows reusable workflows from `nbari/release-flow`; the `candidate-storage` and `publish-*` environments, with their variables and secrets; and the `main` ruleset's required status check renamed to `candidate / Candidate OK`.

<!-- release-flow caller: docs/callers/candidate.yml -->
```yaml
# release-flow candidate pipeline, called at a pinned commit. Copy to
# .github/workflows/candidate.yml; replace __RELEASE_FLOW_SHA__ with the full
# commit SHA that .release-flow.json "pipeline.sha" also names.
name: Candidate

on:
  push:
    branches: ['release/**']

permissions:
  contents: read

jobs:
  candidate:
    uses: nbari/release-flow/.github/workflows/candidate.yml@__RELEASE_FLOW_SHA__
    with:
      adapter: tools/adapter.sh
    permissions:
      contents: read
      id-token: write
```

<!-- release-flow caller: docs/callers/release.yml -->
```yaml
# release-flow publishers, called at a pinned commit. Copy to
# .github/workflows/release.yml; replace __RELEASE_FLOW_SHA__ with the full
# commit SHA that .release-flow.json "pipeline.sha" also names.
name: Release

on:
  push:
    tags: ['[0-9]+.[0-9]+.[0-9]+']
  workflow_dispatch:
    inputs:
      version:
        description: Promoted release version (X.Y.Z)
        required: true
        type: string
      channel:
        description: Channel to (re)publish
        required: true
        type: choice
        options: [github-release, oci, crates-io, docs, helm]

permissions:
  contents: read

jobs:
  release:
    uses: nbari/release-flow/.github/workflows/release.yml@__RELEASE_FLOW_SHA__
    with:
      version: ${{ inputs.version }}
      channel: ${{ inputs.channel }}
    permissions:
      contents: write
      packages: write
      id-token: write
```

The `uses:` ref must be the full commit SHA, not a branch or tag. `scripts/pipeline-pin.sh` enforces that at run time against `job.workflow_sha`, and promotion check PF13 requires the candidate run to have called exactly `<pipeline.repository>/.github/workflows/candidate.yml@<pipeline.sha>`. Bump the pin in one develop commit that changes both `uses:` lines and `pipeline.sha` together. A candidate commit still cannot touch `.github/*` or `.release-flow.json` (PF09).

This path works on github.com only (`job.workflow_repository`, `job.workflow_sha` and `job.workflow_ref` are not available on GitHub Enterprise Server). A called job's `environment:` is an environment in the adopter's repo. crates.io Trusted Publishing still matches the caller file `release.yml` and the environment `publish-crates-io`.

Local commands use the installed managed bundle: `just deploy`, `just release-promote`, `just release-status` and `just release-retry`. A separate checkout at `pipeline.sha` with `--project-dir` also remains supported. Promotion stays local because pushes made with `GITHUB_TOKEN` do not start workflows.

Recovery: `release-retry` dispatches the caller's `release.yml` on `promotion.publisher_ref`. Newer publisher code means bumping the pin on develop and dispatching with `--ref develop`.

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

Promotion and publishing need the optional blocks below (see `docs/release-flow.example.json`). They are validated strictly: unknown keys are rejected, and templates may use only `{project}` and `{version}`.

| Key | Description |
|---|---|
| `repository` | `owner/name` on GitHub; required for promotion and publishing. |
| `promotion.main_branch` | Released branch (default `main`). |
| `promotion.push_remote` | Remote for promotion and tag resolution (default: `remote`); point it at the release deploy key. |
| `promotion.candidate_workflow` | Workflow that validates candidates (default `.github/workflows/candidate.yml`). |
| `promotion.required_job` | Job that must succeed on the candidate (default `Candidate OK`). |
| `promotion.signature_verification` | `github` (GitHub must report the tag verified) or `allowed-signers` (SSH signatures checked against `promotion.allowed_signers`, a path under `.github/`). |
| `promotion.publisher_ref` | Ref `release-retry` dispatches `release.yml` on (default `main`). |
| `storage.uri` | `file:///abs/path` or `s3://bucket/prefix` (`RELEASE_FLOW_STORAGE_URI` overrides); `storage.region`, `storage.endpoint` for S3-compatible stores. |
| `publishers.<channel>` | `github-release` (`assets` globs), `oci` (`artifact`, `repository`, `tags`, `latest_tag`), `crates-io` (`artifact`, `package`, `index_url`; see §9), `docs` (`artifact`, `uri`, `latest`), `helm` (`artifact`, `uri`, `base_url`; the chart's `Chart.yaml` version must equal the release version); each has `required` (counts towards `PUBLISHED`). |
| `pipeline.repository` / `pipeline.sha` | Optional pin of the reusable workflows (`owner/name` and a full 40-hex commit). Absent means this repository's own, or bundle-installed, workflows. See the pinned-SHA subsection of §1. |

---

## 3. Project Adapter Protocol (v1)

Release automation communicates with your project through a single executable adapter specified in `.release-flow.json`.

- For static Marketplace validation, add `# release-flow-adapter: 1` after the interpreter shebang. This declares the six-command v1 contract without executing project code. Shell syntax and interpreter availability are checked; candidate execution verifies actual behavior. Existing binary adapters can keep using workflows/local commands or provide a script wrapper for static Action validation.
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
| `targets` (optional) | None | JSON array of `{"target": "<name>", "runner": "<runs-on label>"}` | None; exit `2` when unsupported (one leg packages everything) |
| `inventory <X.Y.Z>` | Release version | JSON inventory string | None (read-only) |
| `package <X.Y.Z> <outdir>` | Release version, output directory (`SOURCE_DATE_EPOCH` in env; `RELEASE_FLOW_TARGET` selects one target) | Free-form build logs | Builds and writes the artifacts of the selected target (all when unset) into `<outdir>` |

`candidate.yml` packages each target on its runner (`RELEASE_FLOW_TARGET=<target>`), then one `assemble` job requires the union of all legs to equal the full inventory. The Cargo adapter lists targets from `RELEASE_FLOW_CARGO_TARGETS` (`"<rust-target>[:<runner>] ..."`); Windows binaries get `.exe`. Every target gets a `.tar.gz` (GNU tar or `gtar` required). Windows targets also get a `.zip`. Linux targets get a `.deb` and a `.rpm` when the package manifest contains `[package.metadata.deb]` and `[package.metadata.generate-rpm]` (`target/release/<bin>` is the asset path those tools read). A pushed `X.Y.Z` tag starts `release.yml`, which publishes that inventory and does not rebuild it.

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

## 4. Complete shell-only example

Copy the tested example into your consumer repository:

```sh
cp -R /path/to/release-flow/examples/shell/app .
cp /path/to/release-flow/examples/shell/VERSION .
mkdir -p tools
cp /path/to/release-flow/examples/shell/tools/adapter.sh tools/adapter.sh
chmod +x tools/adapter.sh
```

The extracted bundle also contains these files under `examples/shell/`. The
[adapter source](../examples/shell/tools/adapter.sh) implements all six commands,
validates SemVer, refuses nonempty package directories and produces deterministic
archives with GNU tar and `gzip -n`. It needs no Rust, Python or Node toolchain.
Run `tools/adapter.sh verify` locally; `SOURCE_DATE_EPOCH=1234567890
tools/adapter.sh package 0.1.0 /tmp/hello-package` packages the initial version.
Set config `adapter` to `tools/adapter.sh` and `project` to your project name.

Rust consumers may install `--with-cargo-adapter` and use
`scripts/adapters/cargo.sh`. Its CI-specific rustfmt/Clippy, musl and package-tool
setup belongs to the adapter; the shared workflows contain no Rust setup.
Other adapters must install or check their own application prerequisites inside
the appropriate commands. Use a committed toolchain/version lock where possible.

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

1. **`guard`**: Validates candidate branch name, commit trailers, single parent, and ancestry; computes the package matrix and the storage URI.
2. **`test`**: Runs the adapter's `verify` on the exact candidate commit.
3. **`package`** (matrix): Each leg runs the adapter's `package` for its target on its runner.
4. **`assemble`**: Merges the legs, writes `SHA256SUMS` and `manifest.json` (the union must equal the inventory) and uploads `candidate-<sha>-<attempt>`.
5. **`verify`**: In an isolated job, downloads the artifact bundle and runs `scripts/verify-candidate.sh` with pinned SHA-256.
6. **`retain`** (production candidates, storage configured): stores every blob and the candidate record, create-only, from the `candidate-storage` environment.
7. **`report`** (`Candidate OK`): Fails closed if any step failed; publishes a GitHub Step Summary.

Each of `guard`, `assemble`, `verify` and `retain` also checks out the workflow's own commit (`job.workflow_sha`) and runs `scripts/pipeline-pin.sh`, so the scripts always come from the workflow that is running and the project tree stays the caller's.

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

## 7. Durable storage

Provision a bucket (or a shared filesystem path for tests) and set `storage.uri`. Only production candidates that passed every job are retained, by the `retain` job; until storage is configured, candidates are not promotable (promotion check PF17).

- **S3**: the aws CLI must support conditional writes (`--if-none-match`, `--if-match`) and conditional deletes (`delete-object --if-match`, used to release publication locks only while they still name the releasing attempt); providers that ignore them are unsupported. Enable versioning, Object Lock (governance) for the supported recovery period and no lifecycle expiry on `blobs/`.
- **Credentials in Actions** (`scripts/storage/ci-credentials.sh`): repository variable `RELEASE_FLOW_AWS_ROLE_ARN` (GitHub OIDC, `id-token: write`; the OIDC token reaches `aws sts` through a private `0600` file, never the command line), or the secrets `RELEASE_FLOW_S3_ACCESS_KEY_ID` / `RELEASE_FLOW_S3_SECRET_ACCESS_KEY`.
- **IAM permissions** (S3 actions; prefixes relative to the storage URI):

  | Role | Allow | Why |
  | --- | --- | --- |
  | `candidate-storage` (`retain` job) | `s3:PutObject` on `blobs/*` and `candidates/*`, with `s3:if-none-match` required by the bucket policy; `s3:GetObject` on the same prefixes; `s3:ListBucket` | Writes are create-only. A blob or record that already exists (a re-run, or another candidate sharing an artifact) is read back and compared byte for byte instead of overwritten, so without `GetObject` every retry of an existing blob fails. |
  | Publishers (`publish-<channel>`) | `s3:GetObject` and `s3:ListBucket` everywhere; `s3:PutObject` on `releases/*`, `ledger/*`, `locks/*`, `pointers/*`; `s3:DeleteObject` on `locks/*` only | Create-only records are verified by `GetObject` when they already exist; latest pointers use `If-Match`; a lock is deleted with `If-Match` on its ETag after reading it, which S3 authorizes only with `GetObject`. Optionally enforce conditional deletes on `locks/*` in the bucket policy. |
  | Docs and Helm targets (`publishers.docs.uri`, `publishers.helm.uri`) | `s3:GetObject`, `s3:ListBucket`, `s3:PutObject` on their prefix | Create-only uploads (verified by `GetObject` when present) and the CAS-updated `latest.json` / `index.yaml`. |

- The release operator needs read access only.

## 8. Promotion

Apply the rulesets in `docs/RULESETS.md` first. Then, from a clone whose `promotion.push_remote` uses the repository's single write deploy key and with a signing key configured (`user.signingkey`; registered on GitHub in `github` mode or listed in the committed allowed signers file):

```bash
just release-promote release/X.Y.Z-<base12> <candidate-sha> --dry-run   # PF01-PF20 only
just release-promote release/X.Y.Z-<base12> <candidate-sha>
```

Exit codes: `0` promoted or already promoted, `3` precondition rejected (nothing changed), `9` another promotion running, `10` push rejected (rerun reuses the local tag), `11` outcome unknown (rerun reconciles first), `12` version promoted with a different identity, `13` inconsistent remote refs (manual), `14` promoted but GitHub reports the tag unverified.

When `.release-flow.json` declares `pipeline`, PF13 also requires the candidate run to have called exactly `<pipeline.repository>/.github/workflows/candidate.yml@<pipeline.sha>`; without it, the run must call no reusable workflow.

## 9. Publishing and recovery

The tag push starts `release.yml`: a read-only selection job followed by one independent job per configured channel, each in its own `publish-<channel>` environment. Secrets: `CARGO_REGISTRY_TOKEN` (crates-io), `OCI_USERNAME` / `OCI_PASSWORD` (oci; `ghcr.io` falls back to the job token).

**crates.io.** The publisher repackages the crate at the candidate commit with the cargo version recorded in the manifest (`build_info.tools.cargo`; `release.yml` installs exactly that toolchain) and publishes only byte-identical bytes. Both `cargo package` and `cargo publish` run with `--package <publishers.crates-io.package>` (default: `project`), so in a workspace with several crates set `package` to the crate this release publishes and `artifact` to its `.crate` file; one release publishes one crate. For an alternative registry set `index_url` to its sparse index URL: it is polled for completion and passed to cargo as `--index sparse+<index_url>/`. A publish refused as "already uploaded" (an earlier attempt whose response was lost) is settled by the index: the same checksum succeeds, a different one is a conflict.

```bash
just release-status X.Y.Z [--json]              # PROMOTED, PUBLISHED or INCONSISTENT, plus each channel
just release-retry X.Y.Z oci                    # dispatch release.yml (promotion.publisher_ref, or --ref REF)
just release-retry X.Y.Z oci --local            # run the publisher from this checkout
just release-retry X.Y.Z oci --break-lock       # clear an expired publication lock first
```

`workflow_dispatch` works only once `release.yml` is on the default branch; before that, use `--local`. Retries never rebuild or retag: the identity comes from the signed tag, the bytes from storage.

---

## 10. Current Implementation Status

- **Implemented and Tested:**
  - Branch-aware deploy module (`.justfiles/deploy.just`, `scripts/release-deploy.sh`).
  - Versioned distribution bundle and installer (`scripts/release-flow-bundle.sh`, `scripts/release-flow-install.sh`).
  - Worktree candidate preparation (`scripts/release-prepare.sh`).
  - Adapter protocol v1 (with optional `targets`) and Cargo reference adapter (`scripts/adapters/cargo.sh`).
  - Multi-platform candidate pipeline, versioned artifact manifest v1 and independent verifier.
  - Durable content-addressed storage and candidate retention (`scripts/storage/`).
  - Guarded atomic promotion with signed tags and reconciliation (`scripts/release-promote.sh`).
  - Independent, idempotent publishers (GitHub Releases, OCI, crates.io, docs, Helm) with a durable ledger, status and retry.
  - Repository rulesets (`docs/RULESETS.md`, `docs/rulesets/*.json`; applied by the owner).
  - Failure-injection suite (`tests/pipeline/`, 13 suites).

## 11. Marketplace validation, trust and troubleshooting

Use the step-level Action example and complete interface in
[MARKETPLACE.md](MARKETPLACE.md). The Action never runs an adapter or release;
`candidate.yml` and `release.yml` remain the release engine.

On github.com, `job.workflow_repository`, `job.workflow_ref` and
`job.workflow_sha` identify the workflow defining the current job. The consumer's
`github.sha` is checked out independently. Missing runtime context fails closed;
GHES is unsupported for these centralized workflows. See GitHub's
[contexts reference](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts)
and the actual run evidence in [VERIFICATION.md](VERIFICATION.md).

No build job receives publisher secrets. Prefer environment-scoped OIDC and
restrict cloud roles to the consumer repository, intended environment and pinned
reusable workflow. If static storage keys are necessary, add only the named
`RELEASE_FLOW_S3_ACCESS_KEY_ID` and `RELEASE_FLOW_S3_SECRET_ACCESS_KEY` mappings to
the candidate/release caller. Publisher credentials belong in `publish-<channel>`
environments or explicit release caller secret mappings. Do not use
`secrets: inherit`. Environment secrets in a called job belong to the consumer.

An unknown channel, an explicitly requested unconfigured publisher or an empty
publisher selection fails before publisher environments are entered. Optional
publishers can fail without changing the durable release identity; retry the
failed channel. A skipped publisher is not recorded as a successful publication.

For pin mismatches, update both caller SHAs, `pipeline.sha` and the local bundle
in one reviewed integration commit. The installer still refuses modified managed
files. Review its next-step output and commit configuration alongside workflow
upgrades; it intentionally never rewrites project configuration. Build reusable
bundles only from clean committed sources. A dirty bundle reports
`source_tree_clean: false` and cannot generate reusable callers.
