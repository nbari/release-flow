# Release design

The fundamental invariant is: **the commit that is promoted and tagged is exactly the commit whose tests passed, and every public artifact is the immutable artifact that was verified for that commit.** The source SHA is an identity, not an approximation based on a branch name or a version string.

## Branch policy

The owner commits freely to `sandbox` and submits squash PRs to protected `develop`. Other contributors also submit PRs to `develop`. `main` accepts only an authorized release promotion, never ordinary development pushes. Temporary `release/*` branches contain an explicit version-bump commit based on an integration commit. Promotion must reject a changed target, stale candidate, non-fast-forward update, missing CI, or mismatched artifact manifest. Release automation must not rewrite `sandbox`.

## Proposed state machine

A release candidate progresses through `PREPARED` → `VALIDATING` → `VALIDATED` → `PROMOTED`. Its independent publishers then report their own states (`pending`, `running`, `succeeded`, `failed`) for GitHub Release, OCI images, documentation, and Helm. `PUBLISHED` is a derived state only when all required publication channels have succeeded. An optional downstream failure must not erase `PROMOTED` or force another version bump.

`PREPARED` means a candidate commit and version are recorded. `VALIDATED` means the exact source SHA passed required tests, every required build succeeded, and all bytes/digests are present in the candidate manifest. `PROMOTED` means the protected main ref and signed immutable version tag designate that verified commit. Each publisher must check the same immutable manifest before acting. Branch moves and tag creation must have a precise failure boundary; Git's atomic push can provide this boundary only for refs on the same Git remote, not for registries and deployment services.

## Independent publication

A failed GitHub Release upload should be repaired by rerunning the GitHub publisher for the same version and SHA. It must not trigger rebuilding, retesting unrelated platforms, creating a new tag, or rewriting an existing tag. Image publication should move validated digest references, not rebuild images. Documentation and Helm should be separate recovery domains, with a guard against stale versions overwriting newer `latest` pointers. Every publisher must be idempotent; a retry must either discover identical already-published state or fail on conflicting content.

For immutable GitHub Releases, stage assets in a draft, verify the complete checksum inventory, and publish only after verification. Reruns must not rely on overwriting assets after publication. Retain candidate bundles in durable storage before their temporary Actions artifacts expire. Detect artifacts missing due to retention and fail clearly instead of secretly rebuilding under an old tag.

## Required failure tests before first production tag

1. CI fails before promotion: `main`, `develop` and tags remain unchanged.
2. Candidate completes but target integration branch advances: refuse stale promotion.
3. The process is interrupted after tag creation: safe recovery without tag rewriting.
4. GitHub Release publication fails after promotion: rerun only that publisher.
5. Image tagging fails while GitHub Release succeeds: rerun image publisher only.
6. Two release promotions race: exactly one succeeds, no duplicate version tags.
7. A digest or checksum differs from its manifest: publication is refused.
8. An older publisher finishes late: it must not roll back mutable `latest` references.
9. Artifact storage expires or is missing: report unrecoverable source artifact, do not fabricate replacement bytes.

## Milestone 1: Candidate preparation and verification

`PREPARED` and `VALIDATED` are now fully implemented and automated:
- Candidate preparation runs in an isolated Git worktree via `just release-prepare` (`scripts/release-prepare.sh`).
- The version bump happens inside the worktree through the project adapter, creating a versioned candidate commit `C` with release trailers (`Release-Version`, `Release-Mode`, `Release-Base-Branch`, `Release-Base-Commit`).
- Base integration branches (`develop` or `sandbox`) and local checkouts remain completely untouched.
- Pushing the candidate branch (`release/**`) triggers `.github/workflows/candidate.yml`, which verifies candidate identity in `guard`, executes project tests and packaging in the same run, writes a versioned `manifest.json` (v1) and `SHA256SUMS`, and downloads and independently verifies the artifacts.
- See [ADOPTION.md](ADOPTION.md) for the Adapter Protocol v1 and adoption guide.