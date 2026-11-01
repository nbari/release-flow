# Rust consumer release operations

The Rust CLI is an ordinary external consumer of nbari/release. The framework
SHA is recorded in `.release-flow.json` and `.release-flow-bundle.json`; both
thin callers and the read-only Action use that exact SHA. This repository owns
the Cargo application, `tools/adapter.sh` and package policy checks. All engine
files are installed and checksum-managed, with no local modifications.

## Installation and upgrades

The installed framework revision is recorded in `.release-flow-bundle.json`.
It is a reviewed source snapshot whose framework VERSION is 0.0.0, rather than
a signed production framework distribution. Reproduce the installed GitHub-only
toolset from this application's clean checkout:

```bash
RF_SOURCE="$(mktemp -d)"
RF_OUTPUT="$(mktemp -d)"
RF_SHA="$(jq -er .source_commit .release-flow-bundle.json)"
git clone https://github.com/nbari/release.git "$RF_SOURCE/source"
git -C "$RF_SOURCE/source" checkout --detach "$RF_SHA"
test -z "$(git -C "$RF_SOURCE/source" status --porcelain)"
bash "$RF_SOURCE/source/scripts/release-flow-bundle.sh" \
  --version 0.0.0 --out "$RF_OUTPUT" --workflow-mode reusable --profile github
tar -xzf "$RF_OUTPUT/release-flow-bundle-0.0.0.tar.gz" -C "$RF_OUTPUT"
bash "$RF_OUTPUT/release-flow-bundle-0.0.0/install.sh" \
  --target . --with-cargo-adapter
```

Use `--upgrade` for a later reviewed bundle. Review conflicts; never overwrite
managed local edits silently. Upgrade the Action pin, pipeline SHA, callers and
bundle source together. Do not manually edit installed engine files or recipes.
The root Justfile imports `.justfiles/deploy.just`.

With Cargo support, the GitHub profile has 22 managed files: 19 scripts
(including the generic Cargo adapter), the Just module and two workflow callers.
It retains every Just operation and local GitHub publisher recovery.
Compared with the full bundle it omits 15 scripts: remote candidate/runtime
helpers, inactive publishers, S3/filesystem backends, storage credential/bootstrap
helpers and the OCI installer. Generic engine regression tests live upstream;
this repository tests its adapter, package policy and exact managed installation.
Switching profiles requires `install.sh --upgrade`, which removes obsolete files
only when their checksums still match the installed lock. Install the full
profile before configuring another local publisher or storage backend.

## Workflow responsibilities

| Workflow | Responsibility |
| --- | --- |
| ci.yml | Development/PR orchestration and stable CI OK aggregate |
| test.yml | Local reusable Rust tests, CLI smoke checks and external read-only Action |
| build.yml | Local reusable Linux/macOS/Windows compilation; no packaging or publishing |
| candidate.yml | Thin external caller: exact-SHA tests, full package matrix, manifest, verification and production retention |
| release.yml | Thin external caller: signed-tag resolution, retained-byte verification and independent publication/recovery |

Only ci.yml triggers the local reusable test/build workflows. They have no
independent push triggers, so the ordinary matrix runs once. Candidate branches
run the separate authoritative candidate workflow, not a second ordinary matrix.
All build/test tokens are read-only. No publisher secrets are inherited.

## Configured candidate matrix

| Rust target | Native runner | Artifacts |
| --- | --- | --- |
| x86_64-unknown-linux-musl | ubuntu-24.04 | TAR.GZ, DEB, RPM |
| aarch64-unknown-linux-musl | ubuntu-24.04-arm | TAR.GZ, DEB, RPM |
| x86_64-unknown-linux-gnu | ubuntu-24.04 | TAR.GZ, DEB, RPM |
| aarch64-unknown-linux-gnu | ubuntu-24.04-arm | TAR.GZ, DEB, RPM |
| x86_64-apple-darwin | macos-15-intel | TAR.GZ |
| aarch64-apple-darwin | macos-15 | TAR.GZ |
| x86_64-pc-windows-msvc | windows-2025 | ZIP, TAR.GZ |
| aarch64-pc-windows-msvc | windows-11-arm | ZIP, TAR.GZ |
| any | ubuntu-24.04 | .crate source artifact only |

GitHub lists these runner labels in its [hosted-runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
Actual execution evidence is recorded after validation; a configured target alone
is not proof that packaging succeeded. The adapter declares exactly 19 artifacts.
The framework distribution bundle is never an application release artifact.

The generic Cargo adapter installs Rust targets and pinned Cargo DEB/RPM tools.
The consumer supplies native musl compiler/linker settings, GNU tar on macOS/Git
Bash Windows, and Linux RPM inspection tools. Python standard-library checks
verify ELF/Mach-O/PE machine headers, libc loader, DEB/RPM architecture and binary
payloads. Application builds need their own tools; the read-only Action still
needs only Bash, Git and jq and never invokes this adapter.

GNU DEBs use automatic runtime dependency detection; musl binaries remain static.
RPM payload checks use rpm2archive and require its successful exit. RPM 4.18's
[older rpm2cpio utility](https://github.com/rpm-software-management/rpm/blob/rpm-4.18.2-release/rpm2cpio.c)
incorrectly rejects packages without the optional archive
size field even after emitting the full payload. No extractor errors are ignored.

## Production prerequisites and sequence

Storage immutability and the protected release-flow-storage branch already exist.
The candidate-storage environment must allow trusted production release branches;
publish-github-release must allow trusted numeric tags and operator recovery refs.
Do not change or reset historical storage. Only github-release is configured;
selecting any other channel fails closed without publishing elsewhere.

Main requires the external check `candidate / Candidate OK` and reserves updates
for authorized guarded promotion. Main/develop deletion, linear-history and
non-fast-forward rules, immutable candidate/tag rules and develop's CI OK review
policy remain enforced. The owner-authorized policy transition was applied on
2026-11-01 before preparing the first external production candidate.

The applied request bodies are [main integrity](rulesets/main-integrity.json)
and [main promotion](rulesets/main-promotion.json), for existing IDs 26284550 and
26284554 respectively. The first requires the externally verified candidate
aggregate, which includes production retention. The second reserves main updates
for the existing administrator role through guarded promotion. Neither introduces
a bypass on integrity or immutable tags. Future policy changes require owner
authorization and review of live drift; do not create duplicate rulesets or
blindly overwrite another administrator's changes.

Start with `git switch sandbox` and `just deploy`. Test-only candidates compile
and package for real but cannot be promoted; durable retention is skipped.

For a later explicitly authorized production release:

```bash
git switch develop
git pull --ff-only
just deploy
just release-candidates
just release-status X.Y.Z --json
just release-promote release/X.Y.Z-<base12> <full-candidate-sha> --dry-run
# Review exact source/runtime identity, successful CI, immutable retention,
# signing authorization and every promotion guard before proceeding:
just release-promote release/X.Y.Z-<base12> <full-candidate-sha>
just release-status X.Y.Z --json
```

Choose the next unused SemVer from the verified tags; never reuse 0.1.2. Fix a
failed candidate on sandbox/develop and prepare a new immutable candidate. A
stale production base requires a fresh candidate. Promotion creates the signed
tag and atomically advances main/develop; publishing retrieves verified original
bytes from storage and does not build. No production release is authorized by
the integration implementation task.

For an independently failed GitHub publisher, use
`just release-retry X.Y.Z github-release`; inspect its run, assets, digest-bound
manifest and durable receipt. Missing bytes or provenance fail closed. Do not
delete/move tags, replace immutable assets or rebuild a promoted version.

## Verification state

Local Rust checks passed: formatting, strict locked Clippy, 27 unit tests, eight
CLI integration tests, release build and nine consumer contract tests.

- [Development CI](https://github.com/nbari/release-flow/actions/runs/41319304447)
  passed at `2c84f329f9fadde35924ee51e818c8f70bde8520`, including the external
  read-only Action, reusable test/build jobs and native Linux/macOS/Windows
  executable smoke tests.
- [Complete sandbox test candidate](https://github.com/nbari/release-flow/actions/runs/41319387642)
  passed at source `79befc01dd216a70a8440aa8fa9292bd6d60c373`, with framework
  runtime `d9604935e9bdadd9ba2ab18af9a8290a39899ac6`. All eight native binary
  targets, the source-crate leg, manifest assembly, independent verification and
  `candidate / Candidate OK` passed. Production retention was skipped.

The complete downloaded inventory has 19 artifacts. Manifest SHA-256:
`5c418c493a2fc1ba861a977a2f262b4e8c1158c9435fe92509fa7b272bdffdf2`.
All machine types and Linux package metadata/payloads were rechecked locally.
Both Linux AMD64 executables report version 0.1.3 and the exact candidate source
SHA. The `.crate` records that same source and excludes the managed engine.
Missing-file and byte-corruption probes were both rejected by the real verifier.

This run was prepared with `just deploy` from the actual sandbox branch after
the authorized history cutover, using the normal `test_base: sandbox` setting.
It supplements the earlier isolated
[validation run](https://github.com/nbari/release-flow/actions/runs/41315382368).
Its base is `2c84f329f9fadde35924ee51e818c8f70bde8520`. Promotion dry-run rejects
it at PF05 because test-only candidates are never promotable. Completed test
branch pointers may be pruned after verification and backup; run evidence and
artifact identities remain recorded here.

Before the root reset, the existing GitHub backend read historical 0.1.2 as
PUBLISHED with its original manifest. After the intentionally unrelated history
cutover, `release-status 0.1.2` reports INCONSISTENT because current main/develop
no longer contain the old release commit. Its verified tag, immutable release,
digest-bound storage binding and successful publisher receipt remain intact.
Inspect the historical tag/archive for that release; do not retry or recreate it
to change this ancestry verdict. New candidates descend from the clean root.

Immutable releases are enabled. candidate-storage allows
`release/*` branches; publish-github-release allows main/develop and numeric tags.
The old storage branch and release identities were unchanged by that test. The
main promotion policy described above is now active.

Production candidate retention, guarded promotion and GitHub publication are
separate later authorized stages. None occurred during this integration test.
