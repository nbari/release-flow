# release-flow

[![CI · sandbox](https://github.com/nbari/release-flow/actions/workflows/ci.yml/badge.svg?branch=sandbox)](https://github.com/nbari/release-flow/actions/workflows/ci.yml?query=branch%3Asandbox)
[![CI · develop](https://github.com/nbari/release-flow/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/nbari/release-flow/actions/workflows/ci.yml?query=branch%3Adevelop)
[![Stage: bootstrap](https://img.shields.io/badge/stage-bootstrap-orange)](#implementation-progress)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue)](LICENSE)

**Reliable, independent, and recoverable release workflows.**

`release-flow` is a practical reference project for building software releases that are **validated before promotion**, **promoted without partial Git ref updates**, and **published through independently retryable channels**. Its Rust CLI is useful for inspecting release readiness; the **release pipeline is the primary project**. The project will eventually release its own binary using the process described here, then serve as a reusable pattern for other repositories.

> **Status: bootstrap / design in progress.** The Rust CLI (`status`, `plan`, `check`), CI, and a basic candidate artifact verifier exist. Versioned release preparation, atomic promotion, immutable tags, independent publishing, and recovery commands are **not implemented yet**. Workflow badges report GitHub Actions results, **not** end-to-end release health.

## The release contract

1. **One release = one version + one exact source commit + one verified artifact inventory.** Branch names and "latest" are never sufficient release identities.
2. **Validate before promotion.** All required tests, builds, packages, checksums, and supply-chain checks complete for the *exact candidate SHA*. A failure must not change `main`, `develop`, or a public version tag.
3. **Promote Git refs atomically.** Move `main` and `develop` to the validated commit and create its signed version tag in a single `git push --atomic`. All refs update, or none do. No merge or squash may change the validated commit after the candidate passes.
4. **Never modify a published identity.** No moving/deleting/reusing release tags and no "rebuild the same version" after promotion. A publisher must use the original verified bytes or image digests.
5. **Publication is not a Git transaction.** GitHub Releases, OCI registries, docs, and Helm are separate failure domains. Each can retry independently and idempotently **without a new commit, tag, version, or CI rebuild**.
6. **Fail closed and be observable.** Unknown CI state, stale candidate, missing artifacts, conflicting published content, or insufficient permissions block the affected operation. Record which step succeeded and exactly how to resume.
7. **No hidden branch rewrites.** Release automation never resets, force-pushes, or auto-syncs anyone's `sandbox` branch.

The target is a *recoverable release*, not an impossible all-or-nothing transaction spanning Git and external services.

## Target flow (design; not yet executable)

```text
                          contributor PRs
                               │
sandbox ───── optional squash ─┴────────────► develop @ D
     (never auto-rewritten)                     │
                                                ▼
                                  preflight + version selection
                                                │
                              isolated temporary worktree / branch
                                  release/<version>-<base-sha>
                                                │
                                    versioned commit @ C
                                                │
                                                ▼
                               candidate pipeline for exact C
                           ┌────────────────────────────────┐
                           │ CI / tests / lint / security   │
                           │ build / package / sign         │
                           │ upload / download / verify     │
                           │ durable artifact manifest     │
                           └────────────────────────────────┘
                                                │
                                     C is VALIDATED
                                                │
                               recheck remote refs and rules
                                                │
                          ┌─────────────────────▼──────────────────────┐
                          │ SINGLE ATOMIC GIT PUSH                     │
                          │ main    ─► C  (fast-forward)               │
                          │ develop ─► C  (fast-forward)               │
                          │ tag X.Y.Z ─► C  (signed, immutable)        │
                          └─────────────────────┬──────────────────────┘
                                                │
                                        C is PROMOTED
                                                │
             ┌──────────────────┬───────────────┼────────────────┐
             ▼                  ▼               ▼                ▼
         GitHub Release       OCI images     Documentation     Helm/package
         draft → verify       by digest      versioned docs   indexes
         → publish            → tags         → latest guard   → latest guard
             │                  │               │                │
             └────── independent retries, same C and manifest ────┘
                                                │
                              all required publishers succeeded
                                                ▼
                                            PUBLISHED
```

**Key distinction:** `git push --atomic` gives an atomic boundary **only for Git refs at the same remote**. Artifact stores and deployment targets are reconciled independently afterward. A failed publisher does not roll back a successful promotion.

## Branches and authority

| Ref | Purpose | Who may modify it |
| --- | --- | --- |
| `main` | Released, stable history only | Dedicated release identity through a guarded promotion; no routine human commits |
| `develop` | Integration branch for contributors and CI | PRs by default; authorized maintainer fast-forward when explicitly requested; release promotion |
| `sandbox` | Free-form experimentation and agent work | Its owner or explicitly authorized collaborators; **never** release automation |
| `release/<version>-<base-sha>` | Temporary, isolated versioned candidate | Candidate-preparation automation only |
| `X.Y.Z` | Immutable version tag pointing at the validated release commit | Created once by authorized release promotion |

`main` and `develop` should remain linear; promotion must be a fast-forward of both. `sandbox` commits can be squash-integrated into `develop` **before** creating a candidate, never afterward. An integration-branch change while a candidate is being tested invalidates its promotion eligibility; test a fresh candidate against the new base rather than force-pushing.

**Production protection is not yet configured in this repository.** Before enabling automatic releases, apply and test GitHub rulesets: require trusted checks and signed release commits, block force pushes and unwanted updates, restrict `main` promotion to a dedicated release actor, and prohibit version-tag update/deletion. An unconditional "PR required" policy on `main` conflicts with direct atomic promotion: choose an explicitly constrained release-actor bypass (or a different promotion design), never a blanket admin bypass. The actor still must independently verify the exact candidate and ref ancestry.

## Detailed release protocol

### 1. Preflight and candidate preparation

From up-to-date `develop`, choose `patch`, `minor`, `major`, or an explicitly supported unreleased-current version. Compute the version relative to the latest *promoted* version, not merely the local manifest. Refuse a dirty checkout, missing tools/credentials, tag collision, unexpected divergence, or another active promotion.

Create an **isolated Git worktree** and a versioned candidate commit `C` on a temporary `release/*` branch. Update the Cargo workspace version and lockfile, plus any declared version-bearing inputs, *before* testing. The candidate remains separate from `main` and `develop` until fully validated. Keep failed candidates diagnosable; clean them up only after safe resolution.

This is also a good place to produce an auditable release plan: chosen version, base SHA `D`, candidate SHA `C`, changed manifests, required gates, and planned publishing channels.

### 2. One authoritative validation for C

The candidate workflow must identify `C` by SHA, never by whichever commit happens to be at the branch tip when a later step executes.

- Run formatting, Clippy, tests, policy/security checks, and every required platform build for `C`.
- Create distributable archives, packages and OCI images **before** promotion. Keep OCI candidates addressable by immutable digest (not only mutable tags).
- Produce and independently verify a manifest containing the version, candidate commit SHA, base SHA, CI run ID, build/toolchain information, artifact names and SHA-256 digests, and any OCI digest/provenance references.
- Download built artifacts into a separate verification job. Verify complete inventory, exact hashes, source identity, and installation/smoke tests. Reject extra, missing, or mismatched artifacts.
- Retain the validated bytes in **durable, immutable storage** for the supported recovery period. GitHub Actions artifact retention alone is insufficient as a permanent recovery strategy.

Avoid rerunning the entire test/build matrix just because `main` and a tag subsequently point to the already-tested SHA. Ordinary `develop` CI can provide early feedback, but the candidate's verified evidence for `C` is the release authority.

**If validation fails:** no version tag or production refs change. Retry a transient failed stage against the same candidate; if source code or build inputs change, treat that as a **new SHA and new candidate validation**. The unpublished intended version may still be reused because it was never released.

### 3. Guarded, atomic Git promotion

Immediately before promotion, reacquire authoritative remote ref state. Verify the candidate's identity, successful required CI on `C`, manifest availability, signed-commit policy, tag absence, authorization, and that advancing **both** destination branches to `C` is still a fast-forward.

Create an annotated signed version tag on `C`, then use a **single atomic push** for `main`, `develop`, and the tag:

```sh
# Illustrative promotion only: run via the verified release automation.
git push --atomic origin \
  <candidate-sha>:refs/heads/main \
  <candidate-sha>:refs/heads/develop \
  refs/tags/X.Y.Z
```

If any ref is rejected or either branch advances incompatibly, the atomic push fails: **no ref is partially promoted**. Do not force-push. Verify the remote result afterward and record `PROMOTED` only when the remote tag, `main` and `develop` match the validated identity. Never treat a lost CLI response as evidence that promotion failed: inspect the remote before retrying.

### 4. Independent, idempotent publishers

All publishers first resolve the immutable **version → C → manifest** record. They must not rebuild binaries or retest unrelated platforms.

| Publisher | Successful state | Safe retry |
| --- | --- | --- |
| GitHub Release | Complete inventory uploaded to a draft, rechecked against the manifest, then published (prefer immutable releases) | Resume an incomplete draft; if already published, verify exact assets and return success or flag conflict |
| OCI images | Validated manifests/indexes copied or tagged by digest | Verify remote digests; retry only missing/mismatched **unpublished** targets, never silently overwrite a conflicting release |
| Documentation | Version-specific content published from the validated source | Retry version-specific publish; update mutable "latest" only if this is still the newest eligible version |
| Helm / package indexes | Versioned package/index entry points at validated artifacts | Retry independently; protect mutable index/latest references from older runs |

**Independent means no artificial `needs: github-release` edge for OCI, documentation, or Helm.** Real dependencies may be modeled explicitly (for example Helm requiring the *image digest*), but a failure in GitHub Release publishing must not block an unrelated image publish.

A GitHub tag workflow has code frozen at its tagged commit. If that publishing logic is broken, recovery must be possible through **current approved publisher code** while still verifying the **original signed tag, candidate SHA, and manifest**. Updating a tag or incrementing the version to escape a workflow bug is forbidden.

For an immutable GitHub Release, upload to a draft, verify all assets, then publish exactly once; do not design retries that require replacing assets after publication.

### 5. Recovery and state reconciliation

Release states are explicit:

```text
PREPARED → VALIDATING → VALIDATED → PROMOTED
                                       │
                                       ├── github-release: pending | running | succeeded | failed
                                       ├── oci:            pending | running | succeeded | failed
                                       ├── docs:           pending | running | succeeded | failed
                                       └── helm:           pending | running | succeeded | failed

PUBLISHED = PROMOTED + all required publishers succeeded
```

The **artifact manifest is immutable**; the publisher status/attempt ledger is separately updateable. Each attempt records version, `C`, channel, workflow run, timestamps, observed digest/state, and an actionable error. Recovery reads actual remote state first; it must not assume that an interrupted job did nothing.

The eventual UX should support individually retrying one publisher without rerunning promotion, for example `release-flow retry X.Y.Z oci` or `just release-retry X.Y.Z oci`. **These commands are proposed, not implemented.**

### Required failure-injection scenarios

| Failure | Expected response |
| --- | --- |
| Build/test/check fails | No `main`/`develop`/tag update; fix or retry candidate |
| `develop` advances after candidate validation | Reject stale promotion; regenerate/revalidate candidate |
| Two promotion attempts race | At most one accepted version/tag promotion |
| Atomic push is rejected | No production ref changes; inspect and retry safely |
| Process loses response after atomic push | Read remote refs/tag; resume publishing if already promoted |
| GitHub Release upload fails | Resume its draft/asset verification only |
| OCI publish fails after GitHub Release succeeds | Retry OCI only, with original digest |
| Old docs/Helm job finishes late | Never replace a newer `latest` pointer |
| Artifact checksum differs / storage expires | Block that publish; do not fabricate replacement bytes |
| Tag-workflow implementation has a bug | Use trusted current recovery workflow; same signed tag + original artifacts |
| Publisher retried twice concurrently | Lock/reconcile; identical result is success, conflict is failure |

These cases must have automated tests **before** production promotion is enabled.

## Current implementation

The existing Rust binary is **read-only**:

```sh
cargo build --locked

cargo run --locked -- status
cargo run --locked -- status --json
cargo run --locked -- plan minor
cargo run --locked -- check
cargo run --locked -- check --local-only --json

just check
just build
```

- `status` inspects the checkout, Cargo version, local/remote tags, branch relationships, and recent Actions runs. Remote information may be unavailable or stale.
- `plan patch|minor|major` previews a version change and blockers; it does not change Git or Cargo files.
- `check` evaluates release eligibility and fails closed when required evidence is missing. `--local-only` limits the checks to local evidence; it is **not** a substitute for authoritative remote CI verification.
- `--json` is intended for CI consumers; automation should inspect both the structured verdict and process exit code.

The [CI workflow](.github/workflows/ci.yml) runs formatting, Clippy, unit tests, candidate verifier failure tests, binary compilation and CLI smoke checks. The [Candidate workflow](.github/workflows/candidate.yml) currently checks for CI on the exact SHA, creates one Linux archive and checksum manifest, then downloads and re-verifies that artifact. **It does not perform the complete release protocol above.**

The candidate workflow is currently `workflow_dispatch`-only and must exist on GitHub's **default branch** before manual dispatch is enabled. With `main` still at the initial bootstrap commit, dispatch cannot yet be used normally. Avoid adding throwaway release tags merely to test this workflow.

## Implementation progress

| Milestone | Status | Exit criterion |
| --- | --- | --- |
| Read-only `status` / `plan` / `check` CLI | **Implemented** | Green [sandbox CI](https://github.com/nbari/release-flow/actions/workflows/ci.yml?query=branch%3Asandbox) |
| Basic CI and candidate archive verification | **Implemented** | Expand to authoritative matrix, verified immutable inventory |
| Bootstrap workflows on default branch | **Pending** | Candidate can be safely dispatched without a release |
| Worktree + versioned temporary candidate | **Planned** | Version changes isolated; no production ref changes |
| Atomic exact-SHA promotion + signed tag + rulesets | **Planned** | Race/stale-branch/partial-push tests pass |
| Durable manifest + independent publishers | **Planned** | Retry one publisher without rebuilding or retagging |
| Complete recovery / fault-injection suite | **Planned** | All failure scenarios demonstrated end-to-end |
| Dogfood a real release of `release-flow` | **Planned** | Self-release can recover interrupted publishers |

**Source of truth:** This README states the intended release contract. [Release design](docs/RELEASE_DESIGN.md) expands the invariants and failure cases; [AGENTS.md](AGENTS.md) covers contributor/agent guidelines. **Do not mistake planned capabilities for working commands.**

Licensed under [BSD-3-Clause](LICENSE).
