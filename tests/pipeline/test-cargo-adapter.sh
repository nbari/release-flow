#!/usr/bin/env bash
# Test Cargo adapter contract implementation.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

adapter="${ROOT}/scripts/adapters/cargo.sh"

t_case "C1: Cargo adapter basic metadata and versioning"
crate_dir="${TF_TMP}/demo-crate"
mkdir -p "${crate_dir}/src"
cat <<'EOF' > "${crate_dir}/Cargo.toml"
[package]
name = "demo-app"
version = "0.1.0"
edition = "2024"

[[bin]]
name = "demo-app"
path = "src/main.rs"
EOF
cat <<'EOF' > "${crate_dir}/src/main.rs"
fn main() {
    println!("demo app");
}
EOF
printf 'Apache-2.0\n' > "${crate_dir}/LICENSE"
printf 'Demo Readme\n' > "${crate_dir}/README.md"

orig_pwd="$(pwd)"
cd "${crate_dir}"
  cargo generate-lockfile --quiet

  t_run bash "${adapter}" version
  assert_rc 0 "C1: read version"
  assert_eq "0.1.0" "${T_OUT}" "C1: version is 0.1.0"

  t_run bash "${adapter}" set-version "0.2.0"
  assert_rc 0 "C1: set-version 0.2.0"
  assert_contains "${T_OUT}" "Cargo.toml" "C1: output includes Cargo.toml"
  assert_contains "${T_OUT}" "Cargo.lock" "C1: output includes Cargo.lock"

  t_run bash "${adapter}" version
  assert_eq "0.2.0" "${T_OUT}" "C1: version successfully updated to 0.2.0"

  t_run bash "${adapter}" set-version "invalid"
  assert_rc 2 "C1: rejected non-semver version"

  t_run bash "${adapter}" inventory "0.2.0"
  assert_rc 0 "C1: inventory succeeds"
  assert_contains "${T_OUT}" "demo-app-0.2.0" "C1: inventory names package and version"

  # Packaging
  out_dir="${crate_dir}/dist"
  export SOURCE_DATE_EPOCH=1700000000
  t_run bash "${adapter}" package "0.2.0" "${out_dir}"
  assert_rc 0 "C1: package succeeds"

  archive_file="$(find "${out_dir}" -name '*.tar.gz')"
  assert_rc 0 "C1: found generated archive"
  assert_contains "${archive_file}" "demo-app-0.2.0" "C1: archive name matches"

  # Check archive contents
  tar_contents="$(tar -tzf "${archive_file}")"
  assert_contains "${tar_contents}" "demo-app" "C1: archive contains binary"
  assert_contains "${tar_contents}" "README.md" "C1: archive contains README"
  assert_contains "${tar_contents}" "LICENSE" "C1: archive contains LICENSE"
cd "${orig_pwd}"

t_finish
