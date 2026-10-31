# Marketplace readiness verification

This is an adversarial self-review and execution record, not an independent
external audit. Production publishing and Marketplace activation are outside
this task's authorization.

## Baseline

Fetched `origin/sandbox` before editing; clean tree at
`29aa847ae0004fa9659897f4ef8130ceda21758f`.

- `just check`: passed (27 Rust unit tests, 8 CLI integration tests, 11 original
  pipeline suites).
- Exact-source [GitHub CI](https://github.com/nbari/release-flow/actions/runs/41227879449): success.
- Downloaded the latest existing successful test candidate from
  [run 41213137466](https://github.com/nbari/release-flow/actions/runs/41213137466)
  at `ed05e452161d6934bd8e9f1c6eda7d8124a074db`. The real verifier accepted all
  five artifacts; manifest SHA-256:
  `3e5e0eb89ceff62309a74be9479cb15dc967ba09bdc936f0e6450601caf31563`.

## Review coverage

| Surface | Coverage and evidence |
| --- | --- |
| Action metadata, trusted entrypoint, consumer paths | Examined; static YAML contract, real entrypoint tests, GitHub runtime test |
| Config schema and adapter boundary | Examined; malformed config, symlink/traversal, whitespace, declared protocol and no-execution tests |
| Workflow/runtime/caller identity | Examined; pin-script negatives, checkout SHA equality, referenced-workflow evidence, live test procedure below |
| Candidate verification and packaging | Examined; guard, matrix, manifest and verifier; exact source and artifact regression suites |
| Local preparation and atomic promotion | Affected callers examined; existing deploy/preparation/promotion failure-injection suites retained |
| Storage, signatures, ledger and publisher recovery | Resolver, credentials, schema and affected orchestration examined; existing fault suites retained |
| Bundle generation, installation and upgrades | Examined; rendered pins, checksums, clean sources, idempotency, drift/conflicts and planted symlink regression |
| Documentation and caller examples | Examined for contract drift; byte-identical canonical caller examples tested |
| Production cloud policies, signing keys and Marketplace UI | Not activated or audited against live production credentials/settings |
| Rust reference application | Unchanged; repository-native checks retained |

Confirmed defects addressed:

- Unknown publishing channel previously skipped every job successfully. A
  read-only plan now fails before any publisher environment. Unconfigured jobs
  are skipped rather than credited as publication successes. Publishers depend
  only on that plan; retries stay independent.
- Missing workflow contexts previously allowed a local checkout fallback. The
  pin now rejects missing identity. In an isolated mutation fixture, restoring
  the old pin script made three updated regression assertions fail (94 pass,
  3 fail); the fixed suite passes all 109 assertions including the pre-checkout bootstrap tests.
- Shared candidate orchestration unconditionally installed Rust tools and ran
  discovered consumer test files. Tool setup and self-tests now belong to the
  relevant project adapters. The reusable engine runs only the declared adapter.
- A development version of static adapter validation could execute an absolute
  consumer interpreter named `bash`. A sentinel regression failed before the
  fix (35 pass, 1 fail), then passed using the runner's shell for syntax checks.
- Installer temporary filenames were predictable and followed planted
  symlinks. The regression demonstrated outside-file overwrite and a symlinked
  managed destination (147 pass, 2 fail). Exclusive `mktemp` files and cleanup
  now protect both payload writes and the managed-file lock.
- The first native self candidate exposed packaging defaults leaking into the
  reference adapter's verification environment. Its Cargo fixture attempted
  unrelated cross targets. B15 reproduced this (149 pass, 1 fail), then passed
  after scoping defaults to targets/inventory/package (150 pass). The failed
  [run 41229529204](https://github.com/nbari/release-flow/actions/runs/41229529204)
  correctly rejected candidate `e356f71e66553f1f611be489d59e0e00aea536f1`;
  the correction requires a fresh candidate SHA, not a mutable runtime retry.
- JSON-encoded NUL in an adapter path could be silently stripped by Bash's
  command substitution. The validator's regression first accepted that invalid
  input (57 pass, 1 fail); the schema now rejects adapter control characters
  before reading the path into shell variables (58 pass).
- Git remote configuration now rejects option-like values; candidate guard
  shares strict config/path validation and uses literal tag comparisons.
- External checkout/artifact Actions are pinned to verified upstream commit
  SHAs. Caller templates no longer inherit all secrets.

Residual trust: an adapter is arbitrary consumer code when candidate/local
operations deliberately execute it. Use trusted release branches and hosted
runners. Protect publisher environments and narrowly scope cloud OIDC trust.
Static validation checks a declaration, syntax and paths, not semantic compliance
of an unexecuted program. No claim is made that arbitrary adapters are safe to
execute with secrets. crates.io retains its existing byte-equality-checked Cargo
repackaging requirement; publishing never substitutes different bytes.

## Reproduce live cross-repository tests

Use an empty isolated repository, with no secrets, storage, production tags or
publishing destinations. From a clean, pushed runtime checkout:

```sh
gh repo create OWNER/release-flow-consumer-test-DATE --private
bash tests/pipeline/live-consumer.sh \
  OWNER/release-flow-consumer-test-DATE \
  "$(git rev-parse HEAD)" /tmp/release-flow-consumer-DATE
```

The script installs the real bundle, calls `just deploy` with the shell adapter,
and pushes only sandbox/test-only candidate branches. It also creates deliberately
rejected config-pin, mutable-workflow-ref and unknown-publisher cases. It never
creates a tag or calls a publisher. Keep the repository to retain run evidence.

Inspect each run's jobs/logs and `referenced_workflows` using `gh api
repos/OWNER/REPO/actions/runs/RUN_ID`. Download the successful `candidate-<SHA>-1`
artifact and run `scripts/verify-candidate.sh --dir DIR --commit SHA`. Assert its
repository/source SHA and `build_info.release_flow.repository/sha` separately.
Require the caller Action job to report the pinned runtime SHA and consumer
project. Negative runs must fail in the pin/selection step, with publisher jobs
skipped. A YAML parser or mocked API is not an end-to-end substitute.

GitHub documents `job.workflow_ref`, `job.workflow_sha` and
`job.workflow_repository` for the called job on github.com; `github` remains the
caller context. See [contexts](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts)
and [reusable workflow behavior](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).
Missing contexts (including GHES) fail closed. Full-SHA `uses` and config pins
remain mandatory. GitHub REST referenced-workflow metadata is checked again at
promotion, independent of the runtime checkout check.

## Tooling

Run `just check`, `just pipeline-test`, `git diff --check`, ShellCheck, yamllint,
and actionlint. The static Action metadata was also parsed with PyYAML locally;
Python is not an Action or consumer runtime dependency.

Actionlint 1.7.12 currently lacks the documented `job.workflow_*` properties.
Use this narrow compatibility suppression while retaining all other expression
and workflow checks; actual GitHub execution is the authority for these fields:

```sh
actionlint \
  -ignore 'property "workflow_(ref|sha|repository)" is not defined in object type' \
  .github/workflows/*.yml
```

ShellCheck 0.11.0 checks all changed shell runtime code and the new tests with
`-x`. Yamllint checks Action/workflow/caller YAML with line length, document-start,
truthy (`on`), and comment-style rules disabled; syntax/indentation/duplicate-key
checks remain enabled. Both downloaded linters were SHA-256 verified against
their upstream release asset metadata.

## Execution results

Local gates passed: `just check` (27 Rust unit tests and 8 CLI integration tests),
`just pipeline-test` (13 suites, 1,423 assertions), ShellCheck for affected runtime
scripts/new tests, yamllint, Action metadata parsing and `git diff --check`.
Actionlint also passed with embedded ShellCheck enabled and only the documented
workflow-property compatibility suppression. Live run URLs follow after execution.

Marketplace
agreement, listing-name acceptance, category selection, first production release,
production cloud destinations and promotion remain **NOT YET ACTIVATED**.

### GitHub cross-repository execution (2026-10-31)

The isolated repository is private; its run URLs require repository access.
All scenarios used the public runtime at
`3045d2cb753aee155013d05cdeb4e9269e3faed4` and no cloud/publisher secrets.

| Scenario | Actual result | GitHub run |
| --- | --- | --- |
| Remote root Action on shell consumer | **VERIFIED ON GITHUB**: success; consumer identity and runtime output asserted | [41229508748](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41229508748) |
| Full reusable candidate with shell adapter | **VERIFIED ON GITHUB**: success; all six required jobs succeeded, retention skipped for test-only mode | [41229509325](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41229509325) |
| Incorrect configuration pin | **VERIFIED ON GITHUB**: expected rejection in runtime pin step | [41229509082](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41229509082) |
| Mutable `@sandbox` workflow reference | **VERIFIED ON GITHUB**: expected rejection, full commit SHA required | [41229510069](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41229510069) |
| Unknown publishing channel | **VERIFIED ON GITHUB**: selection and report failed; all five publishers skipped | [41229511771](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41229511771) |

The positive candidate source was
`d81e650a182ed3e332673553d20ceeb53fd89170`, based on
`c7903989b52e7457d5db202ef7734a623282e5b9`. Its real downloaded artifact was
verified locally, including `VERSION=0.1.1` inside the archive:

- Manifest: `abc934d9ce3f795e0171406766c400ae52b3d5246294e2de40228421d5c5deac`.
- Artifact `hello-0.1.1.tar.gz`:
  `62091dddd476960c7e747626f5c3843e60791d32b7734570efac88a55d6ba2fb`.
- `build_info.release_flow.repository`: `nbari/release-flow`.
- `build_info.release_flow.sha`: `3045d2cb753aee155013d05cdeb4e9269e3faed4`.

Actual guard logs reported:

```text
RF_WORKFLOW_REPOSITORY: nbari/release-flow
RF_WORKFLOW_REF: nbari/release-flow/.github/workflows/candidate.yml@3045d2cb753aee155013d05cdeb4e9269e3faed4
RF_WORKFLOW_SHA: 3045d2cb753aee155013d05cdeb4e9269e3faed4
pipeline_mode=call
pipeline_sha=3045d2cb753aee155013d05cdeb4e9269e3faed4
project=hello
adapter=tools/adapter.sh
```

GitHub's REST `referenced_workflows` contained exactly that path and SHA. The
production evidence helpers `rf_gh_run_pipeline`, `rf_gh_job_ok` and
`rf_gh_candidate_artifact` accepted the actual API responses, including the
`candidate / Candidate OK` job name. This independently establishes the consumer
source and trusted runtime identities; no mocked API was used for these checks.

The expected failures logged, respectively, configuration/workflow SHA mismatch,
`got @refs/heads/sandbox`, and `Unknown publisher channel: unknown`.
No release tags or production publications were created in the test repository.

The public repository's own root Action and full CI also passed at the original
implementation SHA: [run 41229497363](https://github.com/nbari/release-flow/actions/runs/41229497363).
The native candidate above deliberately remains recorded as a failed attempt;
it cannot be promoted. Fresh corrected-candidate results are recorded separately.

### Corrected runtime and managed upgrade

The corrected runtime is `b68d46e396c06897f0e64b760ae33a4430d07e8b`.
Both required local gates passed again on the working checkout: 13 pipeline
suites and 1,423 assertions, plus the 27 Rust unit and 8 CLI integration tests.
The real `scripts/adapters/release-flow.sh verify` entrypoint also passed locally.

The existing consumer upgraded through the real installer: 3 managed files
updated, 30 unchanged, and `--check` reported zero drift. Configuration, caller
pins and the remote Action reference were committed together. Both the
[upgraded remote Action](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41230696836)
and [upgraded candidate](https://github.com/nbari/release-flow-consumer-test-20261031/actions/runs/41230700222)
passed on GitHub.

The latter's source is `88a98ba2f94ca178e4cbcf10100e2eb33044a651`; runtime and
referenced-workflow metadata identify `b68d46e396c06897f0e64b760ae33a4430d07e8b`.
Its downloaded manifest independently verified with SHA-256
`9bf3d4687a4545a43fdec033071e718fa51679cad28957fd7af9cc6c969fc474`.

Restoring the old release workflow in a separate local mutation checkout made
11 workflow-contract assertions fail (98 pass), including all five publisher
selection gates. The current workflow contract passes 109 assertions. This
complements the real unknown-channel rejection, rather than substituting a
static check for execution.

### Successful native candidate

[Corrected exact-SHA CI](https://github.com/nbari/release-flow/actions/runs/41230669022)
passed at `b68d46e396c06897f0e64b760ae33a4430d07e8b`.
The fresh native test candidate
`a95290ef7e4a0ea5747d0a5736ffa7eb3c61f4ba` passed
[run 41230698283](https://github.com/nbari/release-flow/actions/runs/41230698283).
All five packaging legs (Linux x86_64, Linux ARM64, macOS, Windows and
platform-independent), full verification, assembly, independent download
verification and `Candidate OK` succeeded. Durable retention was correctly
skipped for test-only mode.

All 11 downloaded artifacts independently verified: platform archives, Windows
ZIP, Linux DEB/RPM, crate and distribution bundle. Manifest SHA-256:
`4e34a503120d2d78c0ef22d79aa18a227b2dadd6a1e74db924e23f57f4c7493d`.
The manifest runtime SHA equals the native candidate SHA. The actual bundle's
`BUNDLE.json` reports that same source commit, version `0.1.1` and
`source_tree_clean: true`. The bundle retains the default vendored mode;
`--workflow-mode reusable` builds the separately tested thin-caller mode.

These are test-only candidates, not public releases. Production storage,
production promotion, real publisher destinations and Marketplace listing
activation remain **NOT YET ACTIVATED**. The Marketplace Action's live runtime
checks ran on Ubuntu; macOS Action execution and GHES were not exercised. Native
macOS packaging did run successfully. Centralized workflows require github.com.

| Capability | Evidence status |
| --- | --- |
| Root Marketplace Action validation | **IMPLEMENTED**, **TESTED LOCALLY**, **VERIFIED ON GITHUB** |
| Reusable candidate and runtime/source provenance | **IMPLEMENTED**, **TESTED LOCALLY**, **VERIFIED ON GITHUB** |
| Publisher selection and unknown-channel rejection | **IMPLEMENTED**, **TESTED LOCALLY**, **VERIFIED ON GITHUB** |
| Independent production publishing, retention and atomic promotion | **IMPLEMENTED**, **TESTED LOCALLY**, **NOT YET ACTIVATED** for production |
| Just deploy, shell adapter, bundle install and managed upgrade | **IMPLEMENTED**, **TESTED LOCALLY**, **VERIFIED ON GITHUB** |
| Native multi-platform candidate and artifact verification | **IMPLEMENTED**, **TESTED LOCALLY**, **VERIFIED ON GITHUB** |
| Marketplace agreement, name acceptance, categories and listing | **NOT YET ACTIVATED**; owner UI authorization required |
# GitHub-only storage follow-up

The `github://owner/repo` backend passed `just check`, `just pipeline-test`,
actionlint (with the existing narrow context-schema exception), ShellCheck,
yamllint and `git diff --check`. The pipeline now has 14 suites, including 51
GitHub-backend assertions. Tests cover batch sealing, original-byte recovery,
upload interruption, draft starter repair, lost publish/CAS responses, stale
tokens, concurrent creates, lock ownership, mutable-release rejection, incorrect
storage tag targets, truncated listings and read-only owner setup defaults.

A real API smoke test in the isolated public repository
[`nbari/release-flow-storage-test-20261031`](https://github.com/nbari/release-flow-storage-test-20261031)
sealed and downloaded byte-identical fixture data. GitHub reports the internal
storage release `immutable: true`. Real concurrent creates returned `5` and `0`;
the wrong lock owner was refused and the correct owner released its lock.
These API checks alone do not establish reusable-workflow retention: the
cross-repository job-token test is recorded separately after actual execution.
