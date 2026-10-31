# Repository rulesets and permissions

Promotion fails closed (check PF20) until the server enforces what the local
checks assume: `main` and `develop` only fast-forward, `main` carries a
successful `Candidate OK` check, release tags are created once and never
change. Applying these rulesets is an **owner action**; release-flow never
changes repository settings.

## Apply

Each file in `docs/rulesets/` is a request body for the
[repository rulesets API](https://docs.github.com/en/rest/repos/rules#create-a-repository-ruleset):

```bash
for f in docs/rulesets/*.json; do
  gh api -X POST "repos/<owner>/<name>/rulesets" --input "${f}"
done
```

`integration_id` 15368 is GitHub Actions: only checks reported by Actions
satisfy the required contexts. Re-applying creates duplicates; update an
existing ruleset with `gh api -X PUT repos/<owner>/<name>/rulesets/<id> --input <file>`.

| File | Target | Rules | Bypass |
| --- | --- | --- | --- |
| `main-integrity.json` | `refs/heads/main` | deletion, non_fast_forward, required_linear_history, required status check `Candidate OK` | none |
| `main-promotion.json` | `refs/heads/main` | update, creation | the release deploy key (always) |
| `develop-integrity.json` | `refs/heads/develop` | deletion, non_fast_forward, required_linear_history | none |
| `develop-review.json` | `refs/heads/develop` | pull_request, required status check `CI OK` | the release deploy key; repository admins (the explicitly authorized maintainer fast-forward) |
| `release-tags-immutable.json` | `refs/tags/*.*.*`, `refs/tags/v*.*.*` | deletion, update, non_fast_forward | none |
| `release-tags-create.json` | `refs/tags/*.*.*`, `refs/tags/v*.*.*` | creation | the release deploy key |
| `candidates.json` | `refs/heads/release/**` | update, non_fast_forward | none (create and delete stay allowed; candidates are immutable) |

Required status checks also apply to the promotion push: the candidate commit
already carries `Candidate OK` from `candidate.yml`, so the server enforces the
exact-SHA validation as well. `CI OK` is `ci.yml`'s aggregate job; `build.yml`
reports `Build OK`, so the two required contexts are unambiguous.

## Who can do what

| Actor | Can do | How |
| --- | --- | --- |
| Contributors | Pull requests to `develop` | `develop-review` |
| Owner | `sandbox`, `just deploy` (creates `release/**`) | write access |
| Release operator | `just release-promote` | the repository's **only** write deploy key, configured as `promotion.push_remote`, plus a signing key registered on the tagger's GitHub account (`github` mode) or listed in the committed allowed signers file (`allowed-signers` mode). gh token: read actions and rules; `actions:write` to dispatch retries. Storage: read only. |
| `candidate.yml` `retain` job | write `blobs/` and `candidates/` | `candidate-storage` environment; OIDC role limited to PutObject with `s3:if-none-match` enforced by the bucket policy, plus GetObject/ListBucket on the same prefixes (an existing blob or record is read back and compared instead of overwritten) |
| `release.yml` jobs | one channel each | `publish-<channel>` environments (deployment refs: `main`, `develop`, tags `*.*.*`); storage role: Get/List everywhere (GetObject verifies existing create-only records and authorizes conditional lock deletes), Put on `releases/`, `ledger/`, `locks/`, `pointers/`, Delete only on `locks/` (always `If-Match` on the lock's ETag, after checking it names the releasing attempt) |

The `DeployKey` bypass applies to every write deploy key of the repository:
keep exactly one.

## Storage bucket

Versioning on, Object Lock in governance mode with a retention of at least
the supported recovery period, and no lifecycle expiry on `blobs/`. Test-only
candidates are never retained.

## crates.io token

Store `CARGO_REGISTRY_TOKEN` only in the `publish-crates-io` environment,
scoped to `publish-update` and to the crate named by
`publishers.crates-io.package` (default: `project`). In a workspace with
several crates, the publisher passes `--package <package>` to both
`cargo package` and `cargo publish`, so the token never needs rights on the
other crates; publish each further crate from its own release-flow project.

## Bootstrap notes

- `workflow_dispatch` only works once `release.yml` is on the default branch
  (`main`). Until the first promotion carries it there, recover with
  `just release-retry X.Y.Z <channel> --local`.
- Tag-push workflows run the publisher code frozen at the tag. Recovery
  dispatches newer approved code (`--ref`, default `promotion.publisher_ref`)
  against the same signed tag and the same stored bytes.
- Pushes made with `GITHUB_TOKEN` do not start workflows; promotion therefore
  runs locally with the deploy key, so its tag push starts `release.yml`.
