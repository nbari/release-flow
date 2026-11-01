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

All existing Git commits remain ancestors or immutable referenced objects.
Signed version tags, public releases, retained assets and the separate protected
release-flow-storage history stay in this repository. No old tags, storage
branch or release binding is transplanted into nbari/release. Deleting the
framework from the current tree does not remove files from its historic SHAs.

The obsolete main Candidate OK requirement is replaced by Rust CI OK while
history/tag/storage integrity protections remain. Main uses ordinary reviewed
Rust integration; the new framework separately keeps release-only main policy.

## Clean Rust history boundary

The Rust-only snapshot at `58729d30847709553f8e114251adc2256cb812be` was
reproduced byte-for-byte as the signed, zero-parent commit
`c2cde54ad18425994c9aa741f850e37296adc5d1` (`Initial Rust CLI`). The original
22-commit development ancestry remains reachable through the protected branch
`archive/pre-rust-history-reset`, historic tags and candidate refs. An independently
restored all-refs bundle also preserves it. Protected-branch cutover requires a
separate owner decision; preparing a root does not itself replace main/develop.

To inspect historical source without changing a current branch:

```bash
git fetch origin archive/pre-rust-history-reset
git switch --detach 58729d30847709553f8e114251adc2256cb812be
# Published 0.1.2 source remains at its original tag:
git switch --detach 0.1.2
```

The current integration branch descends from the clean root. `git log --all`
continues to show historical evidence intentionally; the archive must not be
removed to shorten that view. No tag, release asset or storage record is moved.

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
