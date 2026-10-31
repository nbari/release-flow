# Discover and prune release candidates

```bash
just release-candidates
just release-candidates --json
just release-prune                    # dry-run by default
just release-prune --dry-run --json
just release-prune --apply            # explicit remote branch deletion
```

Discovery reports version, branch, full commit SHA, validation/run URL, retention,
current or stale base, promotion state and deletion eligibility. It reads remote
refs, exact-commit trailers, paginated GitHub runs, required jobs, retained records
and publication evidence. It never executes an adapter or prepares a release.
JSON has `schema_version: 1`, `kind`, `applied` and `items`; each item includes
`validation`, `retention`, `base_status`, `promotion`, `safe_to_delete` and `reason`.
Remote objects may be fetched into the local object database without changing
local refs, tags, the index or working tree.

Cleanup is conservative:

- Completed test-only candidates can be disposable, including failed tests.
- Production candidates are eligible only after their exact version/source
  binding is fully published, with successful historical required publishers
  and no active publication lock. Changing the current configuration cannot
  waive a publisher required by the candidate's configuration.
- Active CI on any paginated run, unknown evidence, absent validation, legacy
  protection or deletion rules prevent deletion. Unpublished or stale production
  candidates remain for an operator decision; this command does not abandon them.
- Integration branches, storage, signed tags, public releases, artifacts and
  ledger records are never deletion targets.

`--apply` requires one canonical github.com push URL matching `repository`.
It re-reads CI and evidence immediately before deleting and checks each remote
branch still has its expected SHA. One atomic Git push uses exact per-ref leases
and `--no-follow-tags`; a concurrent ref change rejects the deletion batch.
GitHub CI scheduling and Git ref updates do not share a transaction: a run queued
in the final interval cannot be locked out by a client-side tool. Schedule explicit
cleanup during a quiet window; server branch protection remains authoritative.
No scheduled automatic pruning is enabled. Exit codes: 0 success, 1 unavailable
evidence/configuration, 2 usage, 5 changed/refused deletion. A dry run is always safe.

A local signed tag with no corresponding remote tag is **not** proof of promotion.
Use `just release-status VERSION --json` and inspect remote refs before deciding
what to do with an older production candidate. This task does not delete candidates.
