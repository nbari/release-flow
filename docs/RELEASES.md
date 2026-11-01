# Rust consumer release operations

The Rust CLI is an ordinary external consumer of nbari/release. The framework
SHA is recorded in `.release-flow.json` and `.release-flow-bundle.json`; both
thin callers and the read-only Action use that exact SHA. This repository owns
the Cargo application, `tools/adapter.sh` and package policy checks. All engine
files are installed and checksum-managed, with no local modifications.

## Installation and upgrades

The initial integration uses the clean public framework commit
`d9604935e9bdadd9ba2ab18af9a8290a39899ac6`, whose VERSION is 0.0.0. This is a
reviewed source snapshot, not a signed production framework distribution.
From this application's clean checkout:

```bash
RF_SOURCE="$(mktemp -d)"
RF_OUTPUT="$(mktemp -d)"
RF_SHA=d9604935e9bdadd9ba2ab18af9a8290a39899ac6
git clone https://github.com/nbari/release.git "$RF_SOURCE/source"
git -C "$RF_SOURCE/source" checkout --detach "$RF_SHA"
test -z "$(git -C "$RF_SOURCE/source" status --porcelain)"
bash "$RF_SOURCE/source/scripts/release-flow-bundle.sh" \
  --version 0.0.0 --out "$RF_OUTPUT" --workflow-mode reusable
tar -xzf "$RF_OUTPUT/release-flow-bundle-0.0.0.tar.gz" -C "$RF_OUTPUT"
bash "$RF_OUTPUT/release-flow-bundle-0.0.0/install.sh" \
  --target . --with-cargo-adapter
```

Use `--upgrade` for a later reviewed bundle. Review conflicts; never overwrite
managed local edits silently. Upgrade the Action pin, pipeline SHA, callers and
bundle source together. Do not manually edit installed engine files or recipes.
The root Justfile imports `.justfiles/deploy.just`.

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

## Production prerequisites and sequence

Storage immutability and the protected release-flow-storage branch already exist.
The candidate-storage environment must allow trusted production release branches;
publish-github-release must allow trusted numeric tags and operator recovery refs.
Do not change or reset historical storage. Only github-release is configured;
selecting any other channel fails closed without publishing elsewhere.

Before production, main must require the external check `candidate / Candidate OK`
and allow only authorized guarded promotion. Preserve main/develop deletion,
linear-history/non-fast-forward rules, immutable candidate/tag rules and develop's
CI OK review policy. Applying this release-policy transition is an owner action;
the integration does not bypass the existing Rust-main policy to publish a tag.

The exact proposed request bodies are [main integrity](rulesets/main-integrity.json)
and [main promotion](rulesets/main-promotion.json). After owner authorization,
review live ruleset drift and update existing IDs 26284550 and 26284554 respectively;
do not create duplicate rulesets. The first replaces only main's CI OK requirement
with the externally verified candidate aggregate (which includes production
retention). The second reserves main updates for the existing administrator role
through guarded promotion. Neither introduces a bypass on integrity or immutable
tags. These bodies are prepared, not applied by this integration.

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

Local Rust checks and nine adapter/pinning/publisher rejection contracts passed.
[Development CI](https://github.com/nbari/release-flow/actions/runs/41308831485)
passed on the isolated integration source, including external Action execution,
Linux AMD64, macOS ARM64 and Windows AMD64 compilation. Local next-version
fixtures also produced and inspected Linux packages and a source crate containing
no managed release engine. Complete test-candidate evidence will be added after
execution. Production
retention, guarded promotion and GitHub publication are separate later stages;
none may be inferred from a successful test-only candidate.
