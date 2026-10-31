#!/usr/bin/env bash
# Explicit integration harness. Mutates only a fresh, isolated public test repo.
# Retains a synthetic production-mode candidate to exercise the storage job;
# never promotes it or creates a numeric release tag/public application release.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
repository="${1:?Usage: live-github-storage.sh OWNER/release-flow-storage-test-NAME FULL_SHA NEW_DIRECTORY}"
runtime="${2:?Full runtime SHA required}"
directory="${3:?New directory required}"
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/release-flow-storage-test-[A-Za-z0-9._-]+$ ]] || exit 2
[[ "${runtime}" =~ ^[0-9a-f]{40}$ && "$(git -C "${root}" rev-parse HEAD)" == "${runtime}" ]] || exit 2
[[ -z "$(git -C "${root}" status --porcelain)" && ! -e "${directory}" ]] || exit 2
gh api "repos/${repository}" --jq .private | grep -qx false || { echo 'Use a public test repository with active ruleset support' >&2; exit 2; }
[[ -z "$(gh api "repos/${repository}/contents" --jq '.[] | select(.name != "README.md") | .name')" ]] \
  || { echo 'Require a fresh test repository containing only README.md' >&2; exit 2; }
bash "${root}/scripts/storage/github-bootstrap.sh" "${repository}" --apply
git clone --quiet "https://github.com/${repository}.git" "${directory}"
directory="$(cd "${directory}" && pwd -P)"
git -C "${directory}" checkout --quiet -b develop
cp -R "${root}/examples/shell/." "${directory}/"
bundle="$(mktemp -d)"
trap 'rm -rf "${bundle}"' EXIT
bash "${root}/scripts/release-flow-bundle.sh" --version 0.0.0 --out "${bundle}" --workflow-mode reusable >/dev/null
tar -xzf "${bundle}/release-flow-bundle-0.0.0.tar.gz" -C "${bundle}"
bash "${bundle}/release-flow-bundle-0.0.0/install.sh" --target "${directory}" >/dev/null
cd "${directory}"
printf "import '.justfiles/deploy.just'\n" > .justfile
jq --arg r "${repository}" --arg sha "${runtime}" \
  '.repository=$r | .storage={uri:("github://"+$r)} | .pipeline={repository:"nbari/release-flow",sha:$sha}
    | .promotion={required_job:"candidate / Candidate OK"}' .release-flow.json > config.tmp
mv config.tmp .release-flow.json
cat > .github/workflows/action.yml <<EOF
name: Storage consumer Action
on:
  push:
    branches: [develop]
permissions:
  contents: read
jobs:
  validate:
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
        run: printf '%s' "\${RESULT}" | jq -e '.adapter_executed == false and .runtime_revision == "${runtime}"'
EOF
git add .
git -c core.hooksPath=/dev/null commit --quiet -m 'Install GitHub-only shell storage consumer'
git push --quiet -u origin develop
just deploy
echo 'Inspect the exact candidate run, its retained immutable release and materialized manifest. This harness never promotes.'
