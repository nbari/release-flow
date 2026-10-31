# Release verification evidence

This is an execution record and adversarial self-review, not an independent
external audit. Run URLs below identify the tested revisions; they are not claims
that an unrelated newer revision passed. The signed version tag, release manifest
and publication ledger are the authoritative production identities.

## Finalization baseline: 2026-10-31

Fetched the remote before editing. `main`, `develop` and `sandbox` were
`33a7baa34043d685c2c6059ddc8394e32710f421` with a clean working tree.
The separate protected `release-flow-storage` history was not merged or reset.

`just release-status 0.1.1 --json` reported **VALIDATED**. The candidate
`release/0.1.1-33a7baa34043` pointed to
`80209d086665cc7001f4fc26c50701df230896b6`; no remote `0.1.1` tag or production
GitHub Release existed. A local signed annotated tag did exist, object
`c4b51e5d5e78de3dff9a96983b3dd79544051084`, pointing at that candidate. Its SSH
signature verified against the owner's registered signing key. A prior failed
push had left it local. Branch equality was not evidence of promotion.

That tag and all retained 0.1.1 bytes were preserved. Version 0.1.2 was selected
for the finalized code, avoiding reuse of an existing signed local identity.
The previous required crates.io destination was removed from the root config
because this task authorizes GitHub/Marketplace publication only. The crate
archive, Cargo adapter, crates.io plugin and independent recovery tests remain.

## Local verification of the finalization change

`just check` passed: 27 Rust unit tests, 8 CLI integration tests and 1,528 pipeline
assertions across 15 suites. The separate `just pipeline-test` gate also passed
all 15 suites and 1,528 assertions. New coverage includes:

- Candidate discovery and read-only/default cleanup; completed test candidates;
  current/stale bases; paginated active CI; branch protections; API failures.
- Immediate CI rechecks, concurrent ref changes, exact leases, atomic deletion,
  canonical push identity and ambiguous-destination rejection.
- Partially published production candidates staying protected, exact-source
  publication eligibility and historical required publishers surviving config changes.
- Real shell example through an installed bundle: Just deploy, guard, adapter,
  inventory, packaging, manifest, digest verification and retention, with
  application toolchains forbidden.
- Published bundle profile using thin reusable callers, complete shell config,
  and source-consistent SHA pins; install/upgrade/conflict and symlink tests.
- `push.followTags=true` never leaking unrelated tags through preparation or promotion.

ShellCheck 0.11.0 passed at warning severity with SC2034 excluded for shared
library exports/fixture variables. Actionlint 1.7.12 passed with only its known
outdated context-schema diagnostic excluded for `job.workflow_ref`,
`job.workflow_sha` and `job.workflow_repository`. Those properties are now
[officially documented](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#job-context)
and were exercised on GitHub. YAML validation and `git diff --check` passed.
No production candidate pruning was performed.

## Existing GitHub runtime evidence

The following real runs established cross-repository behavior before this
finalization; final release validation must inspect its own exact SHA too.

| Run | Verified behavior |
| --- | --- |
| [Root CI at 33a7baa](https://github.com/nbari/release-flow/actions/runs/41242765502) | `uses: ./`, separate shell-consumer directory, Rust and failure-injection checks |
| [Native production-mode candidate at 80209d0](https://github.com/nbari/release-flow/actions/runs/41238499965) | Exact source, five package legs, all 11 artifacts, manifest/digests and immutable GitHub retention; no promotion |
| [External shell Action](https://github.com/nbari/release-flow-storage-test-20261031/actions/runs/41239106872) | Full-SHA Action at 80209d0 validates the caller without executing its adapter |
| [External reusable candidate](https://github.com/nbari/release-flow-storage-test-20261031/actions/runs/41239110201) | Consumer source d7baabb differs from trusted runtime 80209d0; shell adapter, manifest and GitHub-only retention succeed |
| [Wrong configured pin](https://github.com/nbari/release-flow-storage-test-20261031/actions/runs/41237744444) | Rejected by the identity guard before build or retention |
| [Mutable workflow reference](https://github.com/nbari/release-flow-storage-test-20261031/actions/runs/41237745281) | Rejected before build or retention; storage metadata unchanged |

The native 0.1.1 manifest SHA-256 was
`5ffd9d2808907e72d4b888c40facd5924f101386e956d8322e69cb3cf631c65b`.
The external shell manifest SHA-256 was
`1796c4f6f3330d5c4c840cabdbeb2d55505afb5b609e8eaf47831950f5b2d600`.
Both were independently materialized and verified from immutable GitHub storage.
The synthetic external candidate was never promoted or published as an application.

## Verify the production release

Inspect [production releases](https://github.com/nbari/release-flow/releases/latest)
and the exact [candidate](https://github.com/nbari/release-flow/actions/workflows/candidate.yml)
and [publisher](https://github.com/nbari/release-flow/actions/workflows/release.yml)
runs referenced by its manifest and ledger. Verify the signed tag without moving
it; require `main == develop == candidate_commit` immediately after promotion.
Download the release, check every artifact digest, and confirm bundle version,
`source_commit`, `source_tree_clean: true` and `workflow_mode: reusable`.
`gh release verify` and `gh release verify-asset` verify GitHub's immutable-release
attestations. Test the released full SHA in an external shell consumer.

Root configuration requests only GitHub Release. Other publisher jobs must be
skipped, never credited as required successes. Production publishing must reuse
the retained bytes; it cannot rebuild a promoted version.

## Review coverage and limits

Examined Action metadata and path isolation, config schemas, workflow/runtime
identity, consumer checkout, adapter execution boundaries, prepare/promote pushes,
GitHub/S3/file storage contracts, manifests, binding/ledger/locks, independent
publishers, bundle/installer conflicts and docs. Negative paths are exercised by
failure injection. The new cleanup command rechecks evidence and uses exact Git
leases; CI scheduling cannot be made transactional with a client-side ref push.
See [CANDIDATES.md](CANDIDATES.md) for that operational limit.

GitHub runtime tests used github.com and hosted Linux runners; native macOS and
Windows packages were also built. The composite Action's macOS execution and
GHES were not tested. Workflow identity contexts require github.com. S3 behavior
has local fault coverage; no live AWS account was used.

Marketplace listing activation requires a separate authenticated owner UI step.
CLI authentication does not authenticate the available browser: its publication
page showed GitHub's sign-in screen. No legal agreement was accepted by automation.
Name availability remains subject to GitHub's metadata validation. A GitHub
Release alone is not proof of a public listing; verify the actual returned
Marketplace URL after the owner completes [the publication procedure](MARKETPLACE.md).
