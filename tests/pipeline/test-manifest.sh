#!/usr/bin/env bash
# Test manifest generation and verification logic.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

stage_base() {
  local dir="$1"
  mkdir -p "${dir}"
  printf 'binary content 1\n' > "${dir}/app-1.0.0-x86_64.tar.gz"
  printf 'package content 2\n' > "${dir}/app-1.0.0-aarch64.tar.gz"
}

write_inv() {
  local path="$1"
  cat <<'EOF' > "${path}"
{
  "artifacts": [
    { "name": "app-1.0.0-x86_64.tar.gz", "target": "x86_64" },
    { "name": "app-1.0.0-aarch64.tar.gz", "target": "aarch64" }
  ],
  "build_info": {
    "tools": { "gcc": "12.2" }
  }
}
EOF
}

readonly COMMIT="1111111111111111111111111111111111111111"
readonly BASE="0000000000000000000000000000000000000000"

t_case "M1: Valid manifest generation and verification"
s1="${TF_TMP}/s1"
inv1="${TF_TMP}/inv1.json"
stage_base "${s1}"
write_inv "${inv1}"

t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s1}" --inventory "${inv1}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 0 "M1: manifest generated"
manifest_sha="${T_OUT}"

t_run bash "${ROOT}/scripts/verify-candidate.sh" \
  --dir "${s1}" --commit "${COMMIT}" \
  --version "1.0.0" --mode "production" \
  --base-commit "${BASE}" --project "demo" --repository "example/demo" \
  --run-id "100" --manifest-sha256 "${manifest_sha}"
assert_rc 0 "M1: verified with all filters"
assert_contains "${T_OUT}" "VERIFIED demo 1.0.0 ${COMMIT}" "M1: reports VERIFIED"

t_case "M2: Missing artifact detection"
s2="${TF_TMP}/s2"
inv2="${TF_TMP}/inv2.json"
mkdir -p "${s2}"
printf 'single binary\n' > "${s2}/app-1.0.0-x86_64.tar.gz"
write_inv "${inv2}"

t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s2}" --inventory "${inv2}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 1 "M2: manifest generator failed on missing file"
assert_contains "${T_ERR}" "Missing artifact file(s)" "M2: error specifies missing artifact"

t_case "M3: Unexpected extra file detection"
s3="${TF_TMP}/s3"
inv3="${TF_TMP}/inv3.json"
stage_base "${s3}"
printf 'unexpected payload\n' > "${s3}/stray.bin"
write_inv "${inv3}"

t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s3}" --inventory "${inv3}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 1 "M3: manifest generator rejected unexpected file"
assert_contains "${T_ERR}" "Unexpected file(s)" "M3: error specifies unexpected file"

t_case "M4: Duplicate artifact in inventory"
s4="${TF_TMP}/s4"
inv4="${TF_TMP}/inv4.json"
stage_base "${s4}"
cat <<'EOF' > "${inv4}"
{
  "artifacts": [
    { "name": "app-1.0.0-x86_64.tar.gz", "target": "x86_64" },
    { "name": "app-1.0.0-x86_64.tar.gz", "target": "x86_64" }
  ]
}
EOF
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s4}" --inventory "${inv4}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 1 "M4: rejected duplicate artifact in inventory"
assert_contains "${T_ERR}" "Duplicate artifact names" "M4: identifies duplicates"

t_case "M5: Tampered artifact bytes"
s5="${TF_TMP}/s5"
inv5="${TF_TMP}/inv5.json"
stage_base "${s5}"
write_inv "${inv5}"
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s5}" --inventory "${inv5}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 0 "M5: generated manifest"

# Corrupt artifact
printf 'tampered data\n' >> "${s5}/app-1.0.0-x86_64.tar.gz"
t_run bash "${ROOT}/scripts/verify-candidate.sh" --dir "${s5}" --commit "${COMMIT}"
assert_rc 1 "M5: rejected corrupted artifact"
assert_contains "${T_ERR}" "Checksum mismatch" "M5: reports checksum mismatch"

t_case "M6: Manifest digest pin mismatch"
s6="${TF_TMP}/s6"
inv6="${TF_TMP}/inv6.json"
stage_base "${s6}"
write_inv "${inv6}"
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s6}" --inventory "${inv6}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"

fake_pin="0000000000000000000000000000000000000000000000000000000000000000"
t_run bash "${ROOT}/scripts/verify-candidate.sh" --dir "${s6}" --commit "${COMMIT}" --manifest-sha256 "${fake_pin}"
assert_rc 1 "M6: rejected pinned manifest hash mismatch"
assert_contains "${T_ERR}" "Pinned manifest SHA256 mismatch" "M6: reports pin failure"

t_case "M7: Identity mismatch filter"
s7="${TF_TMP}/s7"
inv7="${TF_TMP}/inv7.json"
stage_base "${s7}"
write_inv "${inv7}"
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s7}" --inventory "${inv7}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"

t_run bash "${ROOT}/scripts/verify-candidate.sh" --dir "${s7}" --commit "2222222222222222222222222222222222222222"
assert_rc 1 "M7: rejected wrong commit"
t_run bash "${ROOT}/scripts/verify-candidate.sh" --dir "${s7}" --commit "${COMMIT}" --version "2.0.0"
assert_rc 1 "M7: rejected wrong version filter"

t_case "M8: Directory with subdirectories or symlinks"
s8="${TF_TMP}/s8"
inv8="${TF_TMP}/inv8.json"
stage_base "${s8}"
mkdir "${s8}/nested"
write_inv "${inv8}"
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s8}" --inventory "${inv8}" \
  --project "demo" --repository "example/demo" \
  --version "1.0.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/1.0.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 1 "M8: rejected directory containing subdirectories"

t_case "M9: Adapter packaging fault injection (missing and extra artifacts)"
s9="${TF_TMP}/s9"
mkdir -p "${s9}"
printf '0.1.0\n' > "${s9}/VERSION"
export SOURCE_DATE_EPOCH=1700000000
pushd "${s9}" >/dev/null
STUB_FAULT=package-missing t_run bash "${ROOT}/tests/pipeline/fixtures/stub-adapter.sh" package "0.1.0" "${s9}/out1"
assert_rc 0 "M9: package-missing adapter ran"
inv_tmp="${s9}/inv.json"
bash "${ROOT}/tests/pipeline/fixtures/stub-adapter.sh" inventory "0.1.0" > "${inv_tmp}"
popd >/dev/null
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s9}/out1" --inventory "${inv_tmp}" \
  --project "demo" --repository "example/demo" \
  --version "0.1.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/0.1.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 1 "M9: manifest generator caught missing packaged artifact"

pushd "${s9}" >/dev/null
STUB_FAULT=package-extra t_run bash "${ROOT}/tests/pipeline/fixtures/stub-adapter.sh" package "0.1.0" "${s9}/out2"
assert_rc 0 "M9: package-extra adapter ran"
popd >/dev/null
t_run bash "${ROOT}/scripts/candidate-manifest.sh" \
  --dir "${s9}/out2" --inventory "${inv_tmp}" \
  --project "demo" --repository "example/demo" \
  --version "0.1.0" --mode "production" \
  --base-branch "develop" --base-commit "${BASE}" \
  --candidate-branch "release/0.1.0-000000000000" --candidate-commit "${COMMIT}" \
  --run-id "100" --run-attempt 1 --source-date-epoch 1700000000 --adapter "tools/adapter.sh"
assert_rc 1 "M9: manifest generator caught extra stray packaged file"

t_finish
