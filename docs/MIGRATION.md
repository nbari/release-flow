# Framework separation

The framework was extracted from nbari/release-flow commit
`8c7d444b9e47ae28d0864e8d9fc3c936530f5b5f` into the separate public repository
[nbari/release](https://github.com/nbari/release). The framework's complete
[file ownership inventory](https://github.com/nbari/release/blob/develop/docs/MIGRATION_INVENTORY.md)
records every original tracked path and the adapted shared metadata.

This repository keeps Cargo.toml, Cargo.lock, Rust source and tests, its build
script/toolchain, BSD license and independent Rust CI. The crate/binary name
release-flow and Cargo version 0.1.2 are preserved. crates.io version 0.1.0 and
all historic published versions are untouched. No new package is published.

Historical releases remain reachable through immutable tags. The original
pre-reset snapshot is also preserved in verified offline Git bundles.
Signed version tags, public releases, retained assets and the separate protected
release-flow-storage history stay in this repository. No old tags, storage
branch or release binding is transplanted into nbari/release. Deleting the
framework from the current tree does not remove files from its historic SHAs.

During separation, the obsolete main Candidate OK requirement was replaced by
Rust CI OK while history/tag/storage integrity protections remained. External
release adoption now uses a guarded main promotion policy; see RELEASES.md.

## Clean Rust history boundary

The Rust-only snapshot at `58729d30847709553f8e114251adc2256cb812be` was
reproduced byte-for-byte as the signed, zero-parent commit
`c2cde54ad18425994c9aa741f850e37296adc5d1` (`Initial Rust CLI`). The original
22-commit development ancestry is preserved in verified all-refs backup bundles.
The temporary `archive/pre-rust-history-reset` branch was retired on 2026-11-01
at the owner's request, after restoring the backup and verifying the exact
source tree and complete object integrity. Its dedicated protection rule was
removed with it; release tags, assets and storage were unchanged.

On 2026-11-01 the owner explicitly authorized the history cutover. After successful
push-event Rust CI, main, develop and sandbox were moved to this one-commit root.
Only the two non-fast-forward guards were briefly adjusted for that authorized
operation and immediately restored; required CI and all tag/storage protections
remained enforced. Subsequent application changes descend normally from the root.
Main subsequently advanced through guarded 0.1.3 promotion. Future production
updates continue through the signed promotion path.

To inspect historical source without changing a current branch:

```bash
git fetch origin --tags
# Published source remains at its original tag:
git switch --detach 0.1.2

# Recover the original pre-reset snapshot in an isolated repository:
RF_RESTORE="$(mktemp -d)"
git clone --mirror \
  /home/devops/backups/release-flow/20261101T121908Z/original-all-refs.bundle \
  "$RF_RESTORE/release-flow.git"
git -C "$RF_RESTORE/release-flow.git" show --stat \
  58729d30847709553f8e114251adc2256cb812be
```

The development branches descend from the clean root. `git log --all`
continues to include historical tags and the separate storage history. The
archive branch's retirement does not move any tag, release asset or storage record.

Unused candidate and preparation branch pointers can be pruned after completed
CI and verified backups. Their removal never deletes signed tags, retained bytes
or publication records. Recovery material is retained outside the checkout at
`/home/devops/backups/release-flow/20261101T121908Z`, including an all-refs bundle
and the historical cutover record. Backups support source recovery into an
isolated clone; do not apply the old cutover rollback plan to branches that now
contain published releases. Recover through normal forward commits and preserve
the released source ancestry.

## External consumer integration

The application now adopts nbari/release through a clean pinned public source
checkout, versioned bundle and its real installer, including the optional generic
Cargo adapter. `.release-flow-bundle.json` records managed ownership and the exact
framework source. The consumer wrapper defines targets and source-crate policy;
it does not implement candidate, storage, promotion or publishing engines.

Both thin workflow callers, the step Action and `.release-flow.json` pipeline pin
match the installed bundle's source commit. Candidate source remains a distinct
immutable identity from the trusted workflow/runtime revision. There are no
submodules, shared source directories or private repository dependencies.
GitHub storage continues using the original protected metadata branch without
relabeling old manifests as new-framework provenance. See [RELEASES.md](RELEASES.md)
for readiness, actual test evidence and the separate production authorization.
