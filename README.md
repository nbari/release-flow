# release-flow

[![CI — develop](https://github.com/nbari/release-flow/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/nbari/release-flow/actions/workflows/ci.yml?query=branch%3Adevelop)
[![Candidate pipeline](https://github.com/nbari/release-flow/actions/workflows/candidate.yml/badge.svg)](https://github.com/nbari/release-flow/actions/workflows/candidate.yml)
[![Stage: bootstrap](https://img.shields.io/badge/stage-bootstrap-orange)](#implementation-progress)
[![License: BSD--3--Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)

**A working reference for reliable, independent, and recoverable software releases.**

This repository is an experimental release pipeline that **releases its own Rust CLI**. The CLI offers useful read-only repository diagnostics, but the primary goal is to develop and test a reusable GitHub-native release process that other projects can adopt.

**Current state: bootstrap.** CI and a candidate artifact workflow are implemented; **automated promotion, immutable tags, GitHub Releases, container publishing, and retries are not yet implemented**. Badges show workflow execution status, not release readiness; the candidate badge will not show a run until the workflow is installed on the default branch and dispatched.

## Why this project exists

A successful test run is not a release. A release must preserve the identity of the validated source commit, record exactly which bytes were built, and permit a failed publisher to resume **without bumping the version, moving a tag, or rebuilding different bytes**.

The intended lifecycle is:

```text
sandbox ──(optional squash)──► develop
                                  │
                                  ▼
                          prepare versioned candidate
                                  │
                                  ▼
                        CI + package + verify once
                                  │
                                  ▼
                     promote exact validated SHA to main
                                  │
                                  ▼
                          create immutable signed tag
                                  │
                ┌─────────────────┼──────────────────┐
                ▼                 ▼                  ▼
           GitHub Release      OCI images       Docs / Helm
                │                 │                  │
                └── each publisher retried independently ──┘
```

Only the **CI and candidate verification** portions of this diagram are executable today. See [Release design](docs/RELEASE_DESIGN.md) for the invariants and failure cases we intend to test before enabling promotion.

## Implementation progress

| Capability | Status | Evidence / next step |
| --- | --- | --- |
| Small, read-only Rust CLI (`status`, `plan`, `--json`) | Implemented | Rust tests and CLI smoke tests in CI |
| Rust formatting, Clippy, unit tests, shell failure tests | Implemented | [CI workflow](.github/workflows/ci.yml) |
| Candidate archive, source SHA, checksum manifest | Implemented | [Candidate workflow](.github/workflows/candidate.yml) |
| Independent re-download and checksum verification | Implemented | Candidate `verify` job |
| Versioned candidate commit and complete preflight | Planned | No branch/version mutation in the CLI yet |
| Safe exact-SHA promotion and signed immutable tags | Planned | Requires protection and concurrency tests |
| Independent GitHub Release / OCI / Docs / Helm publishing | Planned | Separate idempotent publishers |
| Retry/resume, provenance, failure injection, multi-platform builds | Planned | Reuse validated artifacts without rebuilding |

*"Implemented" describes code present in this repository, not a claim that GitHub Actions has already passed on every branch. Check the linked workflow badges and runs for live results.*

## Try the CLI

Prerequisites: Rust stable (2024 edition), Git, `just`, `jq`, and optionally authenticated `gh` for remote Actions status.

```sh
cargo build --locked
cargo run --locked -- status
cargo run --locked -- status --json
cargo run --locked -- plan minor
just check
```

`status` reports the current branch/commit, Cargo version, clean/dirty state, latest **local** SemVer tag, and the most recent GitHub Actions runs if `gh` is available. Fetch tags before relying on the local tag view (`git fetch --tags`). `plan patch|minor|major` previews a bump and local blockers; it never modifies files or refs. Both commands support `--json`.

`just check` runs formatting, Clippy, Rust tests, and candidate verification failure tests. The candidate verifier deliberately rejects mismatched commit SHAs, unexpected contents and altered checksums.

## GitHub Actions workflows

- **[CI](.github/workflows/ci.yml)** — push and pull-request checks, plus one `CI OK` status gate. A committed `Cargo.lock` is required.
- **[Candidate](.github/workflows/candidate.yml)** — manual run on `develop` or `release/*` after successful CI on that **exact** commit; creates a Linux x86-64 archive, SHA256SUMS and a manifest; then downloads and verifies the artifact in a separate job. This is **not** a public release.

Once the Candidate workflow is present on GitHub's default branch, start it with:

```sh
gh workflow run candidate.yml --ref develop
# or, when on develop:
just candidate
```

GitHub normally requires a `workflow_dispatch` workflow file to exist on the **default branch**. During the bootstrap phase, when development is on `develop` and `main` remains untouched, the candidate workflow can be reviewed but cannot yet be manually dispatched. Candidate artifacts are retained temporarily by Actions; long-term recovery will require durable storage.

## Branch model

- **`main`** — stable, release-only history; protect it before the first promotion. No ordinary development commits.
- **`develop`** — integration and CI branch. Contributors normally use PRs; the maintainer may authorize a direct fast-forward integration, as with the initial bootstrap.
- **`sandbox`** — personal experimentation, never modified automatically by the release tooling.
- **`release/*`** — temporary exact-SHA, versioned candidates (planned).

Publication of an existing version must be recoverable without touching the original tag. A released source SHA and its artifact checksums are immutable identities, not a promise to rebuild something equivalent later.

## Documentation

[Release design and failure scenarios](docs/RELEASE_DESIGN.md) · [Contributor/agent guidelines](AGENTS.md) · [BSD-3-Clause license](LICENSE)