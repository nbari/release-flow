# GitHub-only artifact retention

Set `storage.uri` to `github://OWNER/REPO`, using the candidate repository:

```json
"storage": {"uri": "github://acme/application"}
```

An owner runs this once with a local GitHub CLI login that has repository
Administration write access:

```sh
bash scripts/storage/github-bootstrap.sh acme/application          # plan
bash scripts/storage/github-bootstrap.sh acme/application --apply  # configure
```

This enables GitHub immutable releases and protects the `release-flow-storage`
branch against deletion and force pushes, without bypass actors. It does not
create a release or move application branches. Keep those protections enabled.
This backend currently supports github.com.
The repository's plan must support active rulesets (public repositories on
GitHub Free, or the appropriate paid plan for private repositories). A private
Free repository is rejected; the backend never ignores unavailable protections.

Candidate retention uploads the verified bytes into a draft prerelease named
`release-flow-store-<manifest SHA256>`, targeting the exact candidate commit.
Assets are named by SHA256. After all uploads finish, the draft is published
with `make_latest: false`. **GitHub must report `immutable: true`** before any
blob index or candidate record is written. Internal storage prereleases appear
in the repository release list; they are separate from public version releases
and do not match the numeric production tag trigger.

The protected orphan branch holds only small metadata: candidate records,
asset pointers, append-only publication events, latest pointers and locks.
Single-parent commits with `force: false` implement atomic compare-and-swap;
concurrent writers retry unrelated changes and reject changed keys. Runtime
scripts never check out or execute that branch. Artifact binaries stay in
Release assets, outside Git history. Each download validates the immutable
release identity, asset membership, server digest, size and actual byte digest.

The Marketplace validation Action remains read-only. Candidate build/test jobs
use `contents: read` and have no publisher secrets. Only the separate retention
job needs `contents: write`; independent publisher jobs also need it for their
ledger and locks. Reusable callers must permit `contents: write` at the calling
job, as shown in the supplied caller template. No storage secret or AWS account
is needed: those jobs use their repository-scoped `GITHUB_TOKEN`. Local
promotion, status and recovery use the operator's `gh` login.

`status`, `plan`, reads and default validation never initialize storage or
create releases. Owner setup is explicit and is refused inside GitHub Actions.
Protect the `candidate-storage` environment to admit only trusted production
candidate branches. Restrict publisher environments to trusted release refs.
No privileged job executes the project adapter.

Retries reuse the same draft and digest-named assets without replacement. A
crash after sealing can recover its indexes and record from the same immutable
release. Existing indexed blobs can be shared across candidates. Never delete
or move storage tags or rewrite the metadata branch. If immutability was not
enabled, retention fails without creating a candidate record; enable it, then
prepare a fresh candidate. Existing mutable releases are never accepted as
durable storage. Original-byte recovery never rebuilds a missing artifact.

GitHub permits assets smaller than 2 GiB and at most 1000 assets per release.
Metadata values are limited to 1 MiB each; a truncated Git tree listing fails
closed. API failures and exhausted bounded CAS retries are retryable failures,
not empty successful reads. Repository administrators remain trusted: the
branch is append-only, but authorized writers can update mutable lock/pointer
keys. Immutable candidate manifests and signed production tags independently
bind source, version and artifact digests. File and S3 storage remain available
for consumers with different retention requirements.

References: [release immutability](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases),
[Git reference updates](https://docs.github.com/en/rest/git/refs#update-a-reference),
[release API](https://docs.github.com/en/rest/releases/releases), and
[release asset limits](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases).
