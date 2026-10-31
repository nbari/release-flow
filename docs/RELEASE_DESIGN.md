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
- `just deploy` / `deploy-minor` / `deploy-major` (`.justfiles/deploy.just` → `scripts/release-deploy.sh`) is the primary entry point. The current branch selects the policy: `test_base` → test-only candidate, `production_base` → production candidate. `main`, `release/*`, a detached HEAD and every other branch are rejected (exit 3) with read-only checks only, so a rejection never changes Git state. Accepted deploys require local `HEAD` to equal the freshly fetched remote base (`--expect-base-commit`), so the commit you are on is exactly the commit released.
- Candidate preparation runs in an isolated Git worktree via `scripts/release-prepare.sh` (also exposed as `just release-prepare`).
- The version bump happens inside the worktree through the project adapter, creating a versioned candidate commit `C` with release trailers (`Release-Version`, `Release-Mode`, `Release-Base-Branch`, `Release-Base-Commit`).
- Base integration branches (`develop` or `sandbox`) and local checkouts remain completely untouched.
- Pushing the candidate branch (`release/**`) triggers `.github/workflows/candidate.yml`, which verifies candidate identity in `guard`, executes project tests and packaging in the same run, writes a versioned `manifest.json` (v1) and `SHA256SUMS`, and downloads and independently verifies the artifacts.
- See [ADOPTION.md](ADOPTION.md) for the Adapter Protocol v1 and adoption guide.
## Milestone 2: Guarded atomic promotion

`PROMOTED` is implemented by `just release-promote <candidate> <sha>` (`scripts/release-promote.sh`). It runs locally with the release operator's credentials (the repository's single write deploy key, configured as `promotion.push_remote`), because pushes made with `GITHUB_TOKEN` do not start workflows and the tag push must start `release.yml`.

**Decide (PF01–PF20, read-only).** Tools; configuration (`repository`, `promotion`); an exclusive local lock; a fresh remote snapshot (with an already-promoted fast path); a production `release/X.Y.Z-<base12>` branch (test-only candidates are never promotable); the `--commit` pin equals the remote branch tip; production trailers; exactly one parent equal to `Release-Base-Commit`; the candidate edits no release tooling (`.github/`, `.justfiles/`, `scripts/`, the config, the adapter, bundle-locked paths), after which the configuration at `C` is authoritative; the version is above every released tag and unused (an unpublished local tag is reused only when it carries exactly this candidate's evidence); `develop` still equals the base; `main` fast-forwards to `C`; the `candidate.yml` push run for `C` on that branch and repository succeeded and its latest attempt's `Candidate OK` job succeeded; the non-expired `candidate-<C>-<attempt>` artifact downloads and verifies; the durable candidate record equals it; every stored blob is present and intact (a missing blob is reported as unrecoverable, never rebuilt); signing is ready; and the server rulesets protect `main`, `develop` and release tags, with a dry-run push accepted.

**Act.** `T1` creates (or reuses) the signed annotated tag whose message carries strict trailers (`Release-Project`, `-Repository`, `-Version`, `-Commit`, `-Base-Commit`, `-Candidate-Branch`, `-Candidate-Run`, `-Candidate-Run-Attempt`, `-Manifest-SHA256`, `-SHA256SUMS-SHA256`, `-Storage`). `T2` re-reads the remote and stops if anything moved. `T3` is the only write: one `git push --atomic` of `C:main`, `C:develop` and the tag, fast-forward and create-only, never forced.

**Reconcile.** `T4` always re-reads the remote (with backoff), whatever the push reported:

| Remote tag | `main` / `develop` | Verdict | Exit |
| --- | --- | --- | --- |
| absent | unchanged | `NOT_PROMOTED`; the local tag is kept and reused on rerun | 10 |
| absent | moved | `STALE`; prepare a new candidate | 3 |
| our tag → `C` | contain `C` | `PROMOTED` (`reconciled=true` when the push reported failure) | 0 |
| another valid signed tag → `C`, same manifest | contain `C` | `PROMOTED_BY_OTHER` | 0 |
| → another commit or manifest | any | `CONFLICT` | 12 |
| → `C` | lack `C` | `INCONSISTENT` (manual; never auto-fixed) | 13 |
| unreachable | — | `UNKNOWN`; rerun reconciles before pushing | 11 |

`T5` (signature mode `github`) requires GitHub to report the tag verified (exit 14 otherwise: the refs are promoted but publishers refuse the tag until the key is registered).

## Milestone 3: Durable storage and independent publication

**Storage** (`scripts/storage/`, `file:///` or `s3://` with conditional writes) is content-addressed and create-only: `blobs/sha256/..` (artifacts, `manifest.json`, `SHA256SUMS`), `candidates/<P>/<C>/<run>-<attempt>.json` (written only by the `candidate.yml` `retain` job), `releases/<P>/<V>.json` (the release binding), the append-only `ledger/` of publication events, `locks/` and `latest` pointers updated by compare-and-swap. Every record has an exact JSON schema (`scripts/lib/schema.sh`); nothing is ever sourced as shell. Identical rewrites succeed, different ones conflict.

**Publishers** (`.github/workflows/release.yml`, one job per channel, no `needs:`) each run `scripts/publication/publish.sh`: resolve the signed tag (strict trailers, trusted signature, `C` contained in `main`), materialize and verify the stored bytes against the pinned manifest digest, take the channel lock, record `running`, observe the destination, apply only what is missing, observe again, record `succeeded` or `failed` with an error class. Channels: GitHub Release (draft → exact asset inventory → publish, never clobber), OCI (push by digest, immutable version tags, forward-only `latest` through a stored pointer and repair), crates.io (repackage at `C`, publish only byte-identical bytes, confirm the index checksum), docs and Helm (create-only objects, CAS-updated pointer/index that only grows).

**Release states** (`just release-status X.Y.Z [--json]`):

```text
PREPARED ─► VALIDATING ─► VALIDATED ─────────────► PROMOTED ─► PUBLISHED
                 │            (run success + durable     │   (every required channel succeeded)
                 │             candidate record)         │
                 ▼                                       ├── <channel>: pending | running | succeeded | failed
         VALIDATION_FAILED     VALIDATED_UNRETAINED      │   (succeeded once any attempt succeeded, else latest event)
                               (no record: not           ▼
                                promotable)          INCONSISTENT (tag exists, a branch lacks C)
```

Optional channel failures never demote `PROMOTED`. **Recovery** is `just release-retry X.Y.Z <channel>`: it dispatches `release.yml` with current approved publisher code (default ref `promotion.publisher_ref`), or runs it from the current checkout with `--local`; the identity still comes only from the original signed tag and the bytes only from storage.

The nine required failure tests above map to PR03, PR06, PR14, PB03, PB08, PR15/PR16, PR09/PB05, PB09 and PR10/PB06 in `tests/pipeline/`.
