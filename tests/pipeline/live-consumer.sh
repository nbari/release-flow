#!/usr/bin/env bash
# Explicit live test, never part of run.sh. Use an EMPTY isolated test repo.
# Creates sandbox and test-only candidate branches; no tags or publishing.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repository="${1:?Usage: live-consumer.sh OWNER/release-flow-consumer-test-NAME FULL_SHA DIRECTORY}"
runtime="${2:?Full runtime SHA required}"
directory="${3:?New local directory required}"
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/release-flow-consumer-test-[A-Za-z0-9._-]+$ ]] || { echo 'Use an isolated release-flow-consumer-test-* repository' >&2; exit 2; }
[[ "${runtime}" =~ ^[0-9a-f]{40}$ && "$(git -C "${root}" rev-parse HEAD)" == "${runtime}" ]] || { echo 'Runtime must be this clean checkout HEAD' >&2; exit 2; }
[[ -z "$(git -C "${root}" status --porcelain)" && ! -e "${directory}" ]] || { echo 'Require clean source and new local directory' >&2; exit 2; }
[[ -z "$(git ls-remote "https://github.com/${repository}.git")" ]] || { echo 'Test repository must be empty' >&2; exit 2; }
mkdir -p "${directory}"
directory="$(cd "${directory}" && pwd -P)"
git -C "${directory}" init --quiet --initial-branch=sandbox
git -C "${directory}" remote add origin "https://github.com/${repository}.git"
cp -R "${root}/examples/shell/." "${directory}/"
bundle_out="$(mktemp -d)"
trap 'rm -rf "${bundle_out}"' EXIT
bash "${root}/scripts/release-flow-bundle.sh" --version 0.0.0 --out "${bundle_out}" --workflow-mode reusable >/dev/null
tar -xzf "${bundle_out}/release-flow-bundle-0.0.0.tar.gz" -C "${bundle_out}"
bash "${bundle_out}/release-flow-bundle-0.0.0/install.sh" --target "${directory}" >/dev/null
cd "${directory}"
printf "import '.justfiles/deploy.just'\n" > .justfile
jq --arg r "${repository}" --arg s "${runtime}" \
  '.repository=$r | .pipeline={repository:"nbari/release-flow",sha:$s} | .promotion={required_job:"candidate / Candidate OK"}' \
  .release-flow.json > config.tmp
mv config.tmp .release-flow.json
cat > .github/workflows/action.yml <<EOF
name: Consumer Action
on:
  push:
    branches: [sandbox]
permissions:
  contents: read
jobs:
  action:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        with:
          persist-credentials: false
      - uses: nbari/release-flow@${runtime}
        id: validation
        with:
          adapter: tools/adapter.sh
      - env:
          RESULT: \${{ steps.validation.outputs.validation-json }}
        run: printf '%s' "\${RESULT}" | jq -e '.project == "hello" and .adapter_executed == false and .runtime_revision == "${runtime}"'
EOF
git add .
git -c core.hooksPath=/dev/null commit --quiet -m 'Install shell consumer test'
git push --quiet -u origin sandbox
base="$(git rev-parse HEAD)"
just deploy

# Rejected candidates deliberately change only test data/configuration. They
# cannot be promoted, and no publishing destination or credential is configured.
for failure in config ref channel; do
  git checkout --quiet --detach "${base}"
  case "${failure}" in
    config)
      version=0.1.2
      jq '.pipeline.sha="0000000000000000000000000000000000000000"' .release-flow.json > config.tmp
      mv config.tmp .release-flow.json
      ;;
    ref)
      version=0.1.3
      sed "s/@${runtime}/@sandbox/" .github/workflows/candidate.yml > caller.tmp
      mv caller.tmp .github/workflows/candidate.yml
      ;;
    channel)
      version=0.1.4
      # A release workflow call with an unknown channel must reject before
      # any publishing environment or destination is entered.
      cat > .github/workflows/candidate.yml <<EOF
name: Reject unknown publisher
on:
  push:
    branches: ['release/**']
permissions:
  contents: read
  packages: write
  id-token: write
jobs:
  release:
    uses: nbari/release-flow/.github/workflows/release.yml@${runtime}
    permissions:
      contents: write
      packages: write
      id-token: write
    with:
      version: 0.1.4
      channel: unknown
EOF
      ;;
  esac
  printf '%s\n' "${version}" > VERSION
  git add .
  git -c core.hooksPath=/dev/null commit --quiet -m "Prepare rejected ${failure} candidate" \
    -m "Release-Project: hello
Release-Version: ${version}
Release-Mode: test-only
Release-Base-Branch: sandbox
Release-Base-Commit: ${base}"
  branch="release/test/${version}-${base:0:12}"
  git push --quiet origin "HEAD:refs/heads/${branch}"
  printf 'negative_%s_sha=%s\n' "${failure}" "$(git rev-parse HEAD)"
done
git checkout --quiet sandbox
printf 'consumer_repository=%s\nconsumer_base=%s\nruntime_sha=%s\n' "${repository}" "${base}" "${runtime}"
