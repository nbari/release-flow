# Adopt Release Flow

Your application supplies an adapter. Release Flow supplies candidate validation,
packaging coordination, durable retention, signed promotion and independent
publishers. The Marketplace Action checks configuration in a step; reusable
workflows orchestrate jobs; the installed Just module handles local operations.

## Installation

Use a clean application Git work-tree root. Local operations require Bash 3.2+,
Git 2.31+, jq 1.6+, Just 1.27+, GitHub CLI and standard Unix tools. Packaging and
bundle creation require GNU tar and gzip on Linux. Adapters choose their own
application tools. The read-only Action only requires Bash, Git and jq.

### A. Download a published verified bundle

The following uses the latest **production** release, excluding internal storage
prereleases. Until a production bundle has been published, use path B below.
GitHub CLI must support `release verify` and `release verify-asset`.

```bash
# Run from your application repository. Downloads stay outside its source tree.
RF_VERSION="$(gh release view --repo nbari/release-flow --json tagName --jq .tagName)"
RF_DOWNLOAD="$(mktemp -d)"
gh release verify "$RF_VERSION" --repo nbari/release-flow
gh release download "$RF_VERSION" --repo nbari/release-flow \
  --pattern "release-flow-bundle-$RF_VERSION.tar.gz" --dir "$RF_DOWNLOAD"
RF_ARCHIVE="$RF_DOWNLOAD/release-flow-bundle-$RF_VERSION.tar.gz"
gh release verify-asset "$RF_VERSION" "$RF_ARCHIVE" --repo nbari/release-flow
tar -xzf "$RF_ARCHIVE" -C "$RF_DOWNLOAD"
RF_BUNDLE="$RF_DOWNLOAD/release-flow-bundle-$RF_VERSION"
RF_SHA="$(jq -er '.source_commit' "$RF_BUNDLE/BUNDLE.json")"
jq -e --arg v "$RF_VERSION" '.bundle_version==$v and .source_tree_clean==true and .workflow_mode=="reusable"' \
  "$RF_BUNDLE/BUNDLE.json"
bash "$RF_BUNDLE/install.sh" --target .
```

The immutable-release attestation verifies repository, tag and asset bytes.
The installer also verifies every file against `BUNDLE.json`. Inspect the signed
version tag and repository's verification evidence when selecting a release.
Do not extract an unverified archive or treat a mutable URL's checksum as a trust root.

### B. Build from a pinned clean source checkout

Select a reviewed, full commit SHA from the repository's signed production tag
(or an explicitly reviewed prerelease source). Set `RF_SOURCE_SHA` to that SHA
and `RF_VERSION` to the version at that commit before running:

```bash
RF_TARGET="$(pwd)"
RF_SOURCE="$(mktemp -d)"
RF_OUTPUT="$(mktemp -d)"
git clone https://github.com/nbari/release-flow.git "$RF_SOURCE/source"
git -C "$RF_SOURCE/source" checkout --detach "$RF_SOURCE_SHA"
test "$(git -C "$RF_SOURCE/source" rev-parse HEAD)" = "$RF_SOURCE_SHA"
test -z "$(git -C "$RF_SOURCE/source" status --porcelain)"
bash "$RF_SOURCE/source/scripts/release-flow-bundle.sh" \
  --version "$RF_VERSION" --out "$RF_OUTPUT" --workflow-mode reusable
tar -xzf "$RF_OUTPUT/release-flow-bundle-$RF_VERSION.tar.gz" -C "$RF_OUTPUT"
RF_BUNDLE="$RF_OUTPUT/release-flow-bundle-$RF_VERSION"
RF_SHA="$(jq -er '.source_commit' "$RF_BUNDLE/BUNDLE.json")"
test "$RF_SHA" = "$RF_SOURCE_SHA"
bash "$RF_BUNDLE/install.sh" --target "$RF_TARGET"
```

The reusable profile requires committed clean runtime sources and installs thin
callers pinned to `BUNDLE.json.source_commit`. The default builder profile,
`--workflow-mode vendored`, remains available for fully vendored workflows; omit
`pipeline` in that mode. Published Release Flow bundles use the reusable profile.
The archive's reproducibility is controlled by source timestamp or `SOURCE_DATE_EPOCH`.

### Configure acme/hello

Continue in the application repository with `RF_BUNDLE` and `RF_SHA` from either
installation path:

```bash
printf "import '.justfiles/deploy.just'\n" > .justfile  # add import to an existing file instead
mkdir -p tools app
cp "$RF_BUNDLE/examples/shell/tools/adapter.sh" tools/adapter.sh
cp "$RF_BUNDLE/examples/shell/app/hello.sh" app/hello.sh
cp "$RF_BUNDLE/examples/shell/VERSION" VERSION
cp "$RF_BUNDLE/examples/shell/.release-flow.json" .release-flow.json
chmod +x tools/adapter.sh
jq -e --arg sha "$RF_SHA" '.pipeline.sha==$sha' .release-flow.json
bash tools/adapter.sh verify
```

For a real repository replace both `acme/hello` identities with its actual
`OWNER/REPO`. Review and commit the generated files and `.release-flow-bundle.json`.
Push approved integration code to `develop` and fast-forward `sandbox` as appropriate.
Do not edit managed workflow internals or deploy recipes. The complete layout
is in [examples/shell](../examples/shell/README.md).

## Configuration

The bundle renders this example with its full source SHA in `pipeline.sha`:

```json
{
  "schema_version": 1,
  "project": "hello",
  "adapter": "tools/adapter.sh",
  "remote": "origin",
  "repository": "acme/hello",
  "production_base": "develop",
  "test_base": "sandbox",
  "pipeline": {"repository": "nbari/release-flow", "sha": "FULL_SHA"},
  "promotion": {
    "main_branch": "main",
    "push_remote": "origin",
    "candidate_workflow": ".github/workflows/candidate.yml",
    "required_job": "candidate / Candidate OK",
    "signature_verification": "github",
    "publisher_ref": "main"
  },
  "storage": {"uri": "github://acme/hello"},
  "publishers": {"github-release": {"required": true, "assets": ["*"]}}
}
```

`FULL_SHA` here denotes the bundle's actual 40-character source commit; the
installed example already has that value. All fields and publisher options are
validated by [the configuration schema](../scripts/lib/schema.sh). Optional
publisher examples are in [release-flow.example.json](release-flow.example.json).
An absent publisher is disabled. An unknown channel is an error. Required
publishers contribute to PUBLISHED only after successful receipts; configuring
an optional publisher still requests its independent execution.

GitHub storage needs immutable releases and a protected `release-flow-storage`
metadata branch. A repository owner explicitly runs:

```bash
bash scripts/storage/github-bootstrap.sh acme/hello        # inspect only
bash scripts/storage/github-bootstrap.sh acme/hello --apply
```

See [GitHub storage](GITHUB_STORAGE.md) for permissions, limits and recovery.
This example uses no AWS account, Docker runtime, crates.io credentials or
external publishing destination. `s3://` and `file:///` remain supported.

## Adapter protocol v1

An adapter is an executable regular file inside the consumer repository. Paths
cannot traverse directories or use symlinks. A shell adapter starts with:

```bash
#!/usr/bin/env bash
# release-flow-adapter: 1
```

Commands run from the consumer project root. JSON belongs on stdout; diagnostics
belong on stderr. Return nonzero on failure. Do not push refs or publish from an
adapter. The [complete executable shell adapter](../examples/shell/tools/adapter.sh)
implements every command:

| Command | Contract |
|---|---|
| `version` | Print current `X.Y.Z`. |
| `set-version X.Y.Z` | Update version files; print each changed relative path on its own line. Only these paths are committed. |
| `verify` | Run the project's pre-release checks. |
| `targets` | Print JSON array, e.g. `[{"target":"any","runner":"ubuntu-24.04"}]`. Exit 2 allows the single-leg compatibility fallback. |
| `inventory X.Y.Z` | Print `{"artifacts":[{"name":"hello-X.Y.Z.tar.gz","target":"any"}],"build_info":{"tools":{"shell":"POSIX"}}}` with the actual version substituted. Declare every output exactly once. |
| `package X.Y.Z OUTDIR` | Write exactly the declared artifacts into an empty output directory. Use numeric `SOURCE_DATE_EPOCH`; honor `RELEASE_FLOW_TARGET` for matrix legs. |

The shell example packages `VERSION` and `app/` reproducibly with GNU tar and
gzip. It is exercised by the real installed candidate pipeline in
`tests/pipeline/test-integration.sh`, alongside the generic adapter protocol tests.

For Rust, install with `--with-cargo-adapter` and set
`adapter: scripts/adapters/cargo.sh`. The Cargo adapter needs Cargo/Rust only in
that project's build environment. The root reference adapter additionally builds
the release-flow bundle and crate archive. It does not make Rust a dependency of
the generic engine. Toolchain installation is the adapter/consumer's responsibility.

## Reusable workflows

The installer produces these exact caller templates with the pin replaced.
Do not set caller concurrency: it can deadlock with the called workflow's group.
Allow workflows from `nbari/release-flow` in the consumer's Actions policy.

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
      contents: write
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

The generic release template exposes permissions for all supported channels.
For GitHub-only publication `packages: write` can be omitted; `id-token: write`
is needed for trusted reusable-workflow identity/OIDC. Candidate jobs do not
inherit publishing secrets. Pass only explicitly named storage credentials
when using S3; use no `secrets: inherit` shortcut.

Create the `candidate-storage` and `publish-github-release` environments in the
consumer. Restrict candidate storage to `release/*`; allow the publishing
environment only on promotion branches and version tags. Review environment
variables and [rulesets](RULESETS.md), including the reusable required check name
`candidate / Candidate OK`. GitHub-only storage uses its scoped workflow token.
Other channels require their own explicitly authorized setup.

## Prepare, promote and recover

```bash
git switch develop
just deploy
just release-candidates
just release-status X.Y.Z --json
just release-promote release/X.Y.Z-<base12> <candidate-sha> --dry-run
just release-promote release/X.Y.Z-<base12> <candidate-sha>
```

`deploy-minor` and `deploy-major` change the bump. Preparation leaves the source
branch unchanged and pushes a create-only candidate. CI validates its trailers,
exact source SHA and workflow/runtime pin, builds its targets and retains its
manifest and verified artifacts. `sandbox` deploys test-only candidates that
cannot be promoted. Promotion requires approved `develop` ancestry, current
bases, passing exact-SHA candidate CI, retained evidence, signing authorization
and the configured deploy-key push identity. It atomically advances `main` and
`develop` and creates an immutable signed tag. Configure a write deploy key as
the push identity; for SSH isolate it from personal multiplexed connections.
Never bypass a ruleset to make promotion pass.

For first release bootstrap, provision rulesets, signing and immutable storage
before preparing the candidate. `main` must be an ancestor of the approved
integration commit. Do not synchronize `main` by ordinary pushes. If prior tags
or branch histories are inconsistent, stop and inspect identities; do not move
tags. See [branches](BRANCHES.md) and the [promotion preconditions](RELEASE_DESIGN.md).

Failed or stale candidates need fixes on the base and fresh validation. A
publication failure keeps its original signed version and bytes:

```bash
just release-status X.Y.Z --json
just release-retry X.Y.Z github-release
```

Retry dispatches only that configured channel through `release.yml`; successful
channels remain independent. Status, planning and validation never push remote
refs or create tags. See [candidate cleanup](CANDIDATES.md) for explicit pruning.

## Upgrades

Download and verify the new bundle as above. Preview drift with the old bundle,
then install the new one:

```bash
bash "$RF_BUNDLE/install.sh" --target . --check
bash "$RF_BUNDLE/install.sh" --target . --upgrade
```

`--check` is read-only. Installation plans every change before writing and
rejects checksum failures, symlinks, unowned conflicts and modified managed
files. Upgrades remove obsolete managed files only when unmodified. The
installer never edits your Justfile, configuration or adapter. Review the lock
file and update your Action pin and `pipeline.sha` to its `source_commit` along
with both rendered workflow pins. Test the upgrade on `sandbox` before integration.

## Troubleshooting

- Missing adapter: commit its executable bit and correct relative path.
- Unsafe path: use regular files inside the project; whitespace is supported.
- Unknown channel/configuration: fix the schema error; disabled channels must be absent.
- Workflow/runtime mismatch: align the Action, callers, config and bundle SHA.
- Missing candidate check: inspect the exact source SHA, run attempt and nested
  reusable job name; never waive checks with a newer unrelated run.
- Retention missing: inspect the storage job and recover its existing immutable
  upload. Do not rebuild an already promoted version.
- Promotion failure: inspect all preconditions, remote refs and signature first.
  A local signed tag alone does not establish remote promotion.
- Release exists but Marketplace is absent: use the owner procedure in
  [MARKETPLACE.md](MARKETPLACE.md) on that existing release.
