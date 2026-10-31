# Release Flow

[![CI](https://github.com/nbari/release-flow/actions/workflows/ci.yml/badge.svg?branch=sandbox)](https://github.com/nbari/release-flow/actions/workflows/ci.yml?query=branch%3Asandbox)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)

**Define how your project builds. Release Flow handles candidate validation,
release provenance, promotion, and publishing.**

A release has one version, one exact source SHA and one verified artifact
inventory. Validate and package a candidate before promotion. Promote Git refs
atomically with a signed immutable tag. Retry each publisher independently using
the original bytes. A failed upload never requires rebuilding or moving a tag.

The pipeline is the product. The small Rust CLI in this repository is a reference
application; consumer projects can use any language, including [shell only](examples/shell).

| Interface | Use it for | Entry point |
| --- | --- | --- |
| Marketplace Action | Read-only configuration and adapter contract validation in a step | `steps[].uses: nbari/release-flow@FULL_SHA` |
| Reusable workflows | Complete candidate and publication jobs | `jobs[].uses: nbari/release-flow/.github/workflows/candidate.yml@FULL_SHA` and `release.yml@FULL_SHA` |
| Just module | Local preparation, promotion, status and recovery | `just deploy`, `release-promote`, `release-status`, `release-retry` |
| Project adapter | Your version, tests, target inventory and packaging | `tools/adapter.sh` |

`FULL_SHA` means a reviewed 40-character commit from this repository. Pin the
Action, both workflows, `.release-flow.json`'s `pipeline.sha` and the local bundle
to the same revision. Floating branches and major-version aliases are not the
recommended interface. The Marketplace listing requires an owner publishing
step; see [MARKETPLACE.md](docs/MARKETPLACE.md).

## Validate in a step

```yaml
permissions:
  contents: read
jobs:
  validate:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          persist-credentials: false
      - uses: nbari/release-flow@FULL_SHA
        with:
          operation: validate
          adapter: tools/adapter.sh
```

The default operation is safe and read-only. It checks the strict configuration
schema, project/adapter paths, interpreter availability and the adapter's declared
protocol without executing project code. Outputs include `validation-json` and
`runtime-revision`. Linux/macOS with Bash, Git 2.31+ and jq are required. See
[all inputs and outputs](docs/MARKETPLACE.md#validate-a-project-in-a-step).

## Run the release pipeline

Commit this as `.github/workflows/candidate.yml`:

```yaml
name: Candidate
on:
  push:
    branches: ['release/**']
permissions:
  contents: read
  id-token: write
jobs:
  candidate:
    permissions:
      contents: write
      id-token: write
    uses: nbari/release-flow/.github/workflows/candidate.yml@FULL_SHA
    with:
      adapter: tools/adapter.sh
```

The consumer owns its source, adapter, configuration, release branches and
credentials. Release Flow checks candidate identity, runs the adapter, packages
its targets, generates a manifest, verifies every artifact and coordinates
retention. The Marketplace Action does not launch this multi-job workflow.

Production can stay entirely on GitHub: [GitHub-only retention](docs/GITHUB_STORAGE.md) uses immutable Release assets, a protected metadata branch and the job token. AWS is optional.

For publishing, commit the complete [release caller](docs/callers/release.yml)
as `.github/workflows/release.yml`, replacing `__RELEASE_FLOW_SHA__` with the
same full SHA. It supports signed tag pushes and single-channel recovery via
`workflow_dispatch`. Each configured publisher has its own environment and
concurrency group. Unknown channels fail; unconfigured publishers are skipped
before obtaining credentials. No publisher depends on another publisher.

## Install the local commands

Use a verified versioned bundle from the same revision as your workflows. It
installs the managed Just module and supporting scripts with conflict detection;
reusable mode installs thin pinned workflow callers. See the complete
[adoption guide](docs/ADOPTION.md) for bundle verification and configuration.

Your root `.justfile` needs only:

```just
import '.justfiles/deploy.just'
```

Implement `version`, `set-version`, `verify`, `targets`, `inventory` and `package`
in one executable adapter. The [complete shell example](examples/shell/tools/adapter.sh)
uses a `VERSION` file and deterministic tar/gzip packaging. Rust projects can
install the existing [Cargo adapter](scripts/adapters/cargo.sh).

```sh
just deploy                         # patch candidate
just deploy-minor                   # minor candidate
just deploy-major                   # major candidate
just release-promote release/X.Y.Z-<base12> <candidate-sha> --dry-run
just release-promote release/X.Y.Z-<base12> <candidate-sha>
just release-status X.Y.Z --json
just release-retry X.Y.Z oci         # retry only OCI; --local also supported
```

Run deploy from a branch equal to its freshly fetched remote: `sandbox`
(`test_base`) prepares a test-only candidate; `develop` (`production_base`)
prepares a production candidate. Preparation uses an isolated worktree and never
rewrites your sandbox. Other branches and detached HEAD are rejected.

Test-only candidates cannot be promoted. Production promotion requires the
exact successful candidate SHA, verified manifest, durable immutable bytes,
unchanged integration base, signing and server rulesets. One atomic push advances
`main` and `develop` and creates the tag. Publication then recovers independently.

## Security and verification

Build jobs have read-only repository permissions and no publisher secrets.
Only retention and selected publisher jobs receive their own environment's
credentials/OIDC permissions. Use hosted runners, protected release branches,
explicitly named secrets and narrowly scoped cloud trust policies. Never execute
untrusted PR adapters in a privileged workflow. All workflow action dependencies
are pinned by SHA; runtime code comes from the called workflow's exact revision.

```sh
just check          # format, Clippy, Rust tests, release failure-injection suites
just pipeline-test  # release invariants and recovery tests
```

[Release design](docs/RELEASE_DESIGN.md) explains the invariants and failure
boundaries. [Rulesets](docs/RULESETS.md) describes required owner protections.
[Verification](docs/VERIFICATION.md) records actual tests and GitHub run evidence.
Production storage, rulesets, signing, the first public release and Marketplace
activation remain owner-controlled deployment steps.

The reference binary offers read-only `status`, `plan patch|minor|major` and
`check` commands (`--json` supported). It is not needed by consumer projects.

Licensed under [BSD-3-Clause](LICENSE).
