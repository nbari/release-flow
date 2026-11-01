# release-flow

A read-only Rust CLI for inspecting Git repository state, release readiness,
SemVer plans, and GitHub Actions results.

[![CI](https://github.com/nbari/release-flow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nbari/release-flow/actions/workflows/ci.yml)
[![crates.io](https://img.shields.io/crates/v/release-flow.svg)](https://crates.io/crates/release-flow)

The release automation framework now lives in
[nbari/release](https://github.com/nbari/release). This repository contains the
Rust application. Its build, tests and CI do not require that framework, Docker,
Node.js or a second source checkout. Consumer integration is planned separately.

## Build and install

Use the stable Rust toolchain configured in `rust-toolchain.toml`, plus Git.
GitHub CLI (`gh`) and authentication are needed to inspect GitHub Actions;
local-only readiness checks work without them.

```bash
git clone https://github.com/nbari/release-flow.git
cd release-flow
cargo build --release --locked
./target/release/release-flow --version
```

The existing published crate identity remains `release-flow`:

```bash
cargo install release-flow --locked
```

The published crate can lag the current source. This migration does not publish
a new crate or change previously published versions. Use the source build to
exercise the commands documented below against the current implementation.

## Inspect a repository

Run from a Cargo project's Git worktree:

```bash
release-flow status
release-flow status --json
release-flow plan patch --json
release-flow plan minor --json
release-flow plan major --json
release-flow check --local-only --json
release-flow check --json
```

- `status` reports branch/commit, working-tree cleanliness, version tags,
  upstream relationships, and available GitHub Actions evidence.
- `plan` calculates a prospective SemVer bump and reports conflicts/blockers.
- `check` evaluates readiness and returns nonzero when blocked or evidence is
  unavailable. `--local-only` skips remote CI checks.

JSON is intended for scripts; human-readable output is available without
`--json`. Use `-v`/`-vv` for diagnostics. Run `release-flow --help` or a command's
`--help` for arguments.

Commands inspect state only. They do not bump versions, prepare candidates,
push branches, create tags, build release artifacts or publish packages. The
current readiness convention expects an integration branch named `develop` and
checks GitHub `CI`/`Candidate` evidence for the exact source commit. A version
already tagged as released is correctly reported as blocked for another release.

## Development

```bash
cargo fmt --all -- --check
cargo clippy --locked --workspace --all-targets --all-features -- -D warnings
cargo test --locked --workspace --all-features
cargo build --release --locked
```

`just check` runs the same gates. Unit tests cover typed command handling, Git
snapshots, SemVer planning and readiness. CLI integration tests create isolated
Git fixtures and mock remote Actions evidence. They need no release engine.

Keep commands, dispatch, actions and domain logic separate. Preserve actionable
errors and fail readiness closed when remote evidence cannot be established.
See [AGENTS.md](AGENTS.md) for contribution conventions.

## Repository and release history

Normal development integrates through `develop`; `main` is protected by the
Rust `CI OK` check and review policy. No crate or GitHub Release is published by
this repository's CI. New publication requires a separate explicit release task.

Historic versions, signed tags, GitHub Releases and retained bytes remain valid.
The protected `release-flow-storage` branch is historical release evidence and
must never be merged, reset, deleted or synchronized with application branches.
Old SHA-pinned Actions remain available from their original immutable commits.

The [migration record](docs/MIGRATION.md) identifies the framework source and
explains future adoption. No Action, reusable release workflow, adapter runtime,
release storage backend or publishing engine is embedded in this application's
current source tree.

BSD-3-Clause licensed. The crates.io package name and repository identity are unchanged.
