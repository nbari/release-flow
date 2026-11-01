# Rust application guidelines

release-flow is a standalone, read-only Rust CLI for inspecting Git repository
state, SemVer plans, release readiness and GitHub Actions evidence. Its crate
and binary names remain release-flow. The release framework lives independently
in nbari/release; no framework integration is enabled in this repository yet.
Use plain imperative commit subjects without conventional prefixes.

Keep clap definitions in cli/commands, typed argument conversion in cli/dispatch,
execution in cli/actions, and Git/version/check logic in the existing domain
modules. Use Command with argument arrays, contextual anyhow errors and typed
reports. Parse external metadata as data; never execute it. Keep commands
read-only: status, plan and check must not change files, refs, tags or releases.

Use rust-toolchain.toml and the committed Cargo.lock. Do not casually change
crate identity, dependencies, compatibility or release versions. Preserve all
historic signed tags, immutable assets, candidate refs and the isolated protected
release-flow-storage branch. Never rewrite published history or publish a crate
without explicit authorization.

Run cargo fmt, strict locked Clippy, locked workspace tests and a locked release
build. Keep CLI integration tests independent of external source checkouts. CI
must build this application without the release framework. Unknown remote/CI
evidence must remain visible and fail readiness checks closed.

Submit normal changes through develop. Authorized maintainers may integrate by
fast-forward after exact-source CI; main requires the Rust CI OK check and
protected review policy. Do not disable protections to force an update. Future
framework adoption is a separate task through its public pinned installation
path; do not vendor an engine or add cross-repository CI dependencies now.
