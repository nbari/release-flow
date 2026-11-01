# release-flow

A read-only Rust CLI for inspecting Git repository state, release readiness,
SemVer plans, and GitHub Actions results.

[![CI](https://github.com/nbari/release-flow/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nbari/release-flow/actions/workflows/ci.yml)
[![crates.io](https://img.shields.io/crates/v/release-flow.svg)](https://crates.io/crates/release-flow)

The release automation framework now lives in
[nbari/release](https://github.com/nbari/release). This repository contains the
Rust application. Its Cargo build and Rust tests run independently. Release
automation consumes that framework at a full commit SHA through its public bundle,
Action and reusable workflows. No Docker or second source checkout is needed
to develop or run the CLI.

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

`just check` runs these gates plus the consumer's release contracts (Bash, jq and
Python 3 are needed for those tooling checks). Cargo tests remain independent.
Unit tests cover typed command handling, Git
snapshots, SemVer planning and readiness. CLI integration tests create isolated
Git fixtures and mock remote Actions evidence. They need no release engine.

Keep commands, dispatch, actions and domain logic separate. Preserve actionable
errors and fail readiness closed when remote evidence cannot be established.
See [AGENTS.md](AGENTS.md) for contribution conventions.

## Repository and release history

Normal development integrates through `develop`. The `CI` orchestrator calls
the local reusable `test.yml` and `build.yml`; both must pass the stable `CI OK`
check. Tests include external read-only Action validation, Rust formatting,
Clippy, unit/integration tests and CLI smoke tests. Ordinary build checks compile
Linux AMD64, macOS Apple Silicon and Windows AMD64. These workflows never publish.

## Release automation

`tools/adapter.sh` owns this application's target and packaging policy. It
delegates Cargo versioning, verification and packaging to the installed generic
adapter. The installer-owned files under `scripts/` and `.justfiles/` are tracked
by `.release-flow-bundle.json`; upgrade them through the framework installer.
The release engine is maintained in nbari/release, with no local implementation
changes. Cargo source and the published crate do not include that engine.

The thin `candidate.yml` and `release.yml` callers use the same reviewed framework
SHA as the validation Action, configuration and installed bundle. Candidate
packaging runs on native architecture runners and declares this inventory:

| Target | Formats |
| --- | --- |
| Linux AMD64 and ARM64, musl and GNU | TAR.GZ, DEB, RPM |
| macOS Intel and Apple Silicon | TAR.GZ |
| Windows AMD64 and ARM64 | ZIP, TAR.GZ containing `.exe` |
| Rust source package | `.crate` artifact; no crates.io publication |

Binary machine headers, Linux package architecture metadata and package
inventories are checked before upload. The framework then assembles the complete
manifest and independently verifies every digest. See [release operations](docs/RELEASES.md)
for the exact matrix, test evidence, required branch policies and recovery.

```bash
git switch sandbox
just deploy                    # real test-only build; never promotable

# A later, separately authorized production release:
git switch develop
just deploy
just release-status X.Y.Z --json
just release-promote release/X.Y.Z-<base12> <candidate-sha> --dry-run
# After reviewing every production precondition:
just release-promote release/X.Y.Z-<base12> <candidate-sha>
```

Promotion creates the signed immutable version tag and atomically advances
main/develop to the verified candidate. The reusable publisher retrieves retained
bytes; it never rebuilds. Only GitHub Release is configured. Recovery uses
`just release-retry X.Y.Z github-release`. Production publication is a separate
operator action, never a side effect of normal build/test CI.

## Historical source

Historic versions, signed tags, GitHub Releases and retained bytes remain valid.
The protected `release-flow-storage` branch is historical release evidence and
must never be merged, reset, deleted or synchronized with application branches.
Old SHA-pinned Actions remain available from their original immutable commits.

The [migration record](docs/MIGRATION.md) identifies the framework extraction,
clean-root boundary and subsequent adoption through the public installation path.

BSD-3-Clause licensed. The crates.io package name and repository identity are unchanged.
