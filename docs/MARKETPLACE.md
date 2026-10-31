# Publish Release Flow Provenance

The root [action.yml](../action.yml) defines the Marketplace Action. Reusable
workflows and the local Just module are complementary interfaces to the same
release infrastructure. Publishing a GitHub Release does **not** by itself
activate a Marketplace listing.

The Action name is **Release Flow Provenance**. On 2026-10-31, an exact-name
Marketplace/web search found no conflicting listing. The name is descriptive,
is not a Marketplace category or a GitHub feature, and contains spaces so it
cannot equal a GitHub account login. Search is not a reservation: the owner must
check GitHub's metadata validation again when publishing. GitHub is the final
authority on name availability.

## Validate a project in a step

Replace `FULL_SHA` with a reviewed 40-character commit from this repository:

```yaml
name: Release configuration
on: [push, pull_request]
permissions:
  contents: read
jobs:
  validate:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          persist-credentials: false
      - uses: nbari/release-flow@FULL_SHA
        id: release-flow
        with:
          operation: validate
          adapter: tools/adapter.sh
      - name: Inspect validation result
        env:
          RESULT: ${{ steps.release-flow.outputs.validation-json }}
        run: printf '%s' "${RESULT}" | jq .
```

Inputs: `operation` defaults to `validate` (the only supported operation),
`project-directory` defaults to `.` relative to `GITHUB_WORKSPACE`, and `adapter`
defaults to `.release-flow.json`'s adapter. An explicit adapter must match the
configuration. All path components must be relative, without traversal or
symlinks. Whitespace is supported. For a monorepo use, for example,
`project-directory: services/my app`; adapter paths remain relative to that
directory.

Outputs are `project`, `project-directory` (absolute), `adapter`,
`runtime-revision`, and `validation-json`. The JSON includes the pipeline pin,
adapter protocol and `adapter_executed: false`. Failed validation exits nonzero
and emits no success outputs. `runtime-revision` is the full Action SHA for a
SHA reference, or checkout HEAD for a local `uses: ./` invocation. A downloaded
branch/tag Action reports `unresolved`; pin by SHA for reliable provenance.

Runtime: Linux or macOS, Bash 3.2+, Git 2.31+, jq 1.6+, standard Unix utilities.
The Action installs nothing, downloads no code, requires no secrets or OIDC,
and needs no token after the caller's checkout. Its scripts come from
`GITHUB_ACTION_PATH`; consumer configuration comes from `GITHUB_WORKSPACE`.
No adapter commands, hooks, tests, builds, Git writes or publication are run.
Adapters declare `# release-flow-adapter: 1` and a valid interpreter shebang.
Shell syntax is checked without executing the adapter or its interpreter.
This checks the **declared** contract; candidate execution checks its behavior.
See the complete [shell example](../examples/shell/tools/adapter.sh).

For untrusted pull requests, run the remote SHA-pinned Action with read-only
permissions on a hosted runner. A local `uses: ./` executes code from the
checked-out revision and is appropriate for this repository's own CI, not a
way to trust arbitrary PR code with credentials. Never execute PR adapters
from `pull_request_target` or another privileged workflow.

## Owner procedure for the first listing

1. Review the exact candidate commit. It must contain root `action.yml`, all
   referenced scripts, both reusable workflows and their dependencies. Run
   `just check` and `just pipeline-test`; inspect exact-SHA GitHub CI, a test-only
   self candidate and the cross-repository evidence in [VERIFICATION.md](VERIFICATION.md).
   Build/install the versioned bundle and verify its `BUNDLE.json.source_commit`
   equals that commit, with `source_tree_clean: true`.
2. Keep the repository public and BSD-3-Clause licensed. GitHub asks action
   repositories to contain only metadata, code and supporting files needed for
   the action. The reference CLI, workflow engine, examples and tests here
   support this release product; avoid adding unrelated applications or assets.
   There must be one root metadata file; no compiled Node distribution is needed.
3. Provision durable storage, signing and the [release rulesets](RULESETS.md)
   before the first production promotion. For [GitHub-only storage](GITHUB_STORAGE.md),
   run the explicit owner bootstrap to enable immutable releases and protect the
   storage branch. Validation and status commands never change those settings.
4. Prepare a **production** candidate from approved `develop`, validate and
   retain it, then authorize `just release-promote <branch> <candidate-sha>`.
   The existing pipeline creates its signed immutable `X.Y.Z` tag and publishes
   the verified assets through `release.yml`. Do not create a different tag in
   the release UI. The pipeline's bare `X.Y.Z` tags are intentional.
5. Sign in as the repository owner with two-factor authentication enabled.
   Open root `action.yml` on GitHub and its **Draft a release** banner, or edit
   the pipeline-created release from **Releases**. Select the **existing**
   signed version tag. If GitHub requires a draft for first-time listing setup,
   prepare the Marketplace fields on the same draft before publication; never
   create a second release/tag or replace verified assets to work around the UI.
6. Accept the **GitHub Marketplace Developer Agreement** using GitHub's link.
   For organization ownership an organization owner must accept it. This is an
   account/legal action; release automation cannot authorize it for the owner.
7. Select **Publish this Action to the GitHub Marketplace**. Address metadata
   errors until GitHub shows **Everything looks good!**. Select a primary
   category (for example **Continuous integration**) and optionally a secondary
   category (for example **Deployment**). Confirm the exact category choices
   offered by GitHub at that time.
8. Enter/review the title and release notes, then **Publish release** or
   **Update release**, according to the existing release's state. Verify the
   resulting listing and installation examples. This Marketplace checkbox,
   categories, agreement and account steps are not performed by `gh release
   create` or our publisher.
9. Document the release's full commit SHA as the recommended reference for the
   Action **and** both reusable workflows. Keep existing tags immutable. Do not
   create or force-update `v1`, `main` or `latest` aliases as an adoption default.

Publication state and exact release/Marketplace URLs are recorded in
[VERIFICATION.md](VERIFICATION.md). A production GitHub Release can exist before
the owner enables Marketplace publication; never infer listing activation from
the release alone.

## Upgrades and troubleshooting

Upgrade Action references, reusable workflow references, configuration
`pipeline.sha` and the local bundle together in a reviewed integration commit.
The bundle manifest records version, source SHA and managed-file checksums;
never fix a mismatch by relaxing provenance checks. See [ADOPTION.md](ADOPTION.md).

- **Missing config/adapter:** checkout the consumer first, set the correct
  project directory and commit the executable bit (`chmod +x tools/adapter.sh`).
- **Protocol declaration missing:** implement all six adapter commands and add
  the declaration. `targets` may return exit 2 to use the single-leg fallback.
- **Interpreter/tool unavailable:** install your adapter's interpreter in the
  caller before validation. Application tools belong inside the adapter.
- **Unsafe path:** replace symlinks with regular files inside the project.
- **Pipeline mismatch:** align both workflow references and `pipeline.sha`.
- **Marketplace checkbox disabled:** the owning account must accept the
  Developer Agreement; check 2FA, public visibility and name validation.
- **Release exists but listing absent:** complete the Marketplace UI steps on
  the existing release. Do not move/delete tags or rebuild its artifacts.

## Official references (checked 2026-10-31)

- [Marketplace prerequisites, naming and owner UI](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace)
- [Action metadata syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/metadata-syntax)
- [Marketplace Developer Agreement](https://docs.github.com/en/site-policy/github-terms/github-marketplace-developer-agreement)
- [Secure use and full-SHA pinning](https://docs.github.com/en/actions/reference/security/secure-use)
- [Immutable releases](https://docs.github.com/en/code-security/concepts/supply-chain-security/immutable-releases)
- [Action versioning](https://docs.github.com/en/actions/how-tos/create-and-publish-actions/using-immutable-releases-and-tags-to-manage-your-actions-releases)

GitHub describes floating aliases as an option. Release Flow retains the stricter
immutable tag/full-SHA policy; Marketplace discoverability does not require them.
