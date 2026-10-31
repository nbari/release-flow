# acme/hello: a complete shell consumer

This application releases a reproducible `hello-X.Y.Z.tar.gz` containing
`VERSION` and a POSIX shell program. Its only publisher is GitHub Release.
No Rust, Docker, AWS account or crates.io token is needed.

Use [either verified installation path](../../docs/ADOPTION.md#installation)
from a clean application Git repository. Continue with its **Configure acme/hello**
commands to copy this adapter, application, version and complete configuration.
The bundle renders the example's `pipeline.sha` to its own clean source commit;
the source-tree example pins an existing reviewed revision for static validation.
Both workflow callers are installed by `install.sh`, rather than copied from
central workflow internals.

```text
acme/hello/
├── .justfile                         # import '.justfiles/deploy.just'
├── .release-flow.json                # actual repository + bundle pin
├── .release-flow-bundle.json          # managed checksums and source revision
├── .justfiles/deploy.just             # managed
├── scripts/                          # managed local release support
├── tools/adapter.sh                  # executable, consumer-owned
├── app/hello.sh
├── VERSION
└── .github/workflows/
    ├── candidate.yml                 # thin pinned caller, managed
    └── release.yml                   # thin pinned caller, managed
```

Replace `acme/hello` with your actual repository in the configuration. Provision
its storage, environments, signing and rulesets using the adoption guide before
production promotion. Review and commit the installation on your integration
branch. The adapter can be exercised directly from this directory:

```bash
bash tools/adapter.sh version
bash tools/adapter.sh verify
bash tools/adapter.sh targets
bash tools/adapter.sh inventory "$(cat VERSION)"
```

`set-version X.Y.Z` changes only `VERSION`; `package X.Y.Z OUTDIR` requires that
version in `VERSION`, an empty output directory and numeric `SOURCE_DATE_EPOCH`.
The candidate workflow supplies that environment and checks the resulting
inventory, manifest and checksums. In an installed consumer:

```bash
git switch develop
just deploy
just release-status X.Y.Z
just release-promote release/X.Y.Z-<base12> <candidate-sha> --dry-run
# After successful CI/retention and operator review:
just release-promote release/X.Y.Z-<base12> <candidate-sha>
```

The executable [adapter](tools/adapter.sh) implements all six protocol commands.
Repository-native integration tests install a real bundle into a shell consumer
and run preparation, candidate verification, signed promotion, failed publication
and independent retry. Live cross-repository evidence is recorded separately in
[VERIFICATION.md](../../docs/VERIFICATION.md).
