#!/usr/bin/env bash
# Runner for all release pipeline test suites.
set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Verify required tools are available (ssh-keygen signs release tags, flock
# serializes the mock S3 store, curl reads the file:// crates index).
for tool in git jq sha256sum tar gzip setsid awk just ssh-keygen flock curl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing required test tool: ${tool}" >&2
    exit 1
  fi
done

# The deploy module needs source_directory() and [group], both from just 1.27.0.
just_version="$(just --version | awk '{print $2}')"
IFS='.' read -r just_major just_minor _ <<< "${just_version}"
if [[ ! "${just_major}" =~ ^[0-9]+$ || ! "${just_minor}" =~ ^[0-9]+$ ]] || \
   (( just_major < 1 || (just_major == 1 && just_minor < 27) )); then
  echo "just >= 1.27.0 required (found: ${just_version:-unknown})" >&2
  exit 1
fi

suite_failures=0
suite_count=0

for test_script in "${test_dir}"/test-*.sh; do
  [[ -f "${test_script}" ]] || continue
  suite_name="$(basename "${test_script}")"
  echo "=== Running pipeline test suite: ${suite_name} ==="
  suite_count=$(( suite_count + 1 ))
  if ! bash "${test_script}"; then
    echo "FAILED: ${suite_name}" >&2
    suite_failures=$(( suite_failures + 1 ))
  else
    echo "PASSED: ${suite_name}"
  fi
  echo ""
done

if (( suite_failures > 0 )); then
  echo "Pipeline test run failed (${suite_failures}/${suite_count} suites failed)" >&2
  exit 1
fi

echo "All ${suite_count} pipeline test suites passed successfully."
exit 0
