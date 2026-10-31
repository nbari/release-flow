# Project guidelines

This project is primarily a reference implementation of safe, independently recoverable release pipelines. Keep the Rust command-line binary intentionally small. For CLI code, follow the existing separation of commands (clap definitions), dispatch (typed argument conversion), actions (execution), and domain modules (Git/version/release logic); do not write a separate architecture tutorial.

Treat source SHA, version, and artifact digest as immutable identities. Keep branch promotion, tag creation, artifact publishing and recovery in separate well-validated steps. Never fix publication by deleting or moving tags, silently rebuilding old versions, or rewriting a developer's sandbox branch. Prefer idempotent, narrowly scoped retries and explicit failure-injection tests.

Contributors normally submit PRs to `develop`; an explicitly authorized maintainer may integrate directly by fast-forward, without a PR. Do not directly update `main`; the production promotion path must be tested and explicitly authorized. Tests and documentation should focus on release invariants and failure recovery, not on CLI scaffolding.

Before proposing release changes: run `just check`, inspect GitHub Actions results on the exact source SHA, and verify candidate manifests. No operation that changes a remote branch or creates a tag belongs in `status` or `plan`.