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
actionlint -shellcheck='' \
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
`just pipeline-test` (13 suites, 1,421 assertions), ShellCheck for affected runtime
scripts/new tests, yamllint, Action metadata parsing and `git diff --check`.
Actionlint also passed with embedded ShellCheck enabled and only the documented
workflow-property compatibility suppression. Live run URLs follow after execution.

Marketplace
agreement, listing-name acceptance, category selection, first production release,
production cloud destinations and promotion remain **NOT YET ACTIVATED**.
