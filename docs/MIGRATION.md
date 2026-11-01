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

## Future external consumer integration (not activated)

A later task may adopt `nbari/release@FULL_SHA` using its public distribution and
installer, with a consumer-owned Cargo adapter and configuration. Both reusable
caller workflows, the step Action, pipeline pin and local bundle must name the
same reviewed framework source revision. Candidate source remains a separate
immutable identity from the trusted workflow/runtime revision.

That adoption will be tested as ordinary cross-repository consumption. It must
not use submodules, shared source directories, privileged internal repository
access or a build/CI dependency on another checkout. This migration intentionally
adds no framework config, caller workflows or runtime to the Rust repository.
