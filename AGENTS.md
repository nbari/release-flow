# Rust application guidelines

release-flow is a standalone, read-only Rust CLI. Keep clap definitions in
cli/commands, typed conversion in cli/dispatch, execution in cli/actions and Git,
version and readiness rules in the domain modules. Prefer Command argument arrays,
contextual anyhow errors and typed reports. Status, plan and check never mutate
files or remote state. Unknown readiness evidence fails closed.

Use plain imperative commit subjects without conventional prefixes. Keep the
crate/binary identity release-flow, the committed toolchain and locked Cargo
dependencies. Run just check, formatting, strict Clippy, workspace tests, release
build, consumer adapter contracts, actionlint and relevant packaging checks.
Cargo development must not require a second framework checkout.

Release orchestration belongs to nbari/release. Installed scripts and Just
recipes are checksum-managed by its public bundle installer; never patch or
maintain a local engine fork. Fix framework defects upstream with regressions,
then upgrade through the installer. Only tools/adapter.sh and application
packaging tests own release-flow-specific policy. Align Action/workflow/config
pins with the installed bundle's full source SHA; no mutable references.

Keep ordinary Rust CI separate from candidate packaging. Use test-only sandbox
candidates as the normal integration regression path. Validate machine types,
package metadata, inventory, manifests and digests; a green build is not evidence
of durable retention, promotion or publication. Build jobs get no publisher secrets.

Preserve signed tags, immutable candidate refs, retained artifacts, publication
records, the isolated storage branch and archived history. Promote only the exact
validated production commit through the guarded atomic signed procedure. Never
rebuild a promoted version or overwrite release assets. Only GitHub Release is
configured; crates.io and other publication require separate explicit authorization.
Do not rewrite protected history or relax integrity checks without owner approval.
