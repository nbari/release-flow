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

t_case "C2: Cargo adapter targets and per-target inventory"
cd "${crate_dir}"
  unset RELEASE_FLOW_CARGO_TARGETS
  t_run bash "${adapter}" targets
  assert_rc 2 "C2: targets unsupported without RELEASE_FLOW_CARGO_TARGETS"
  export RELEASE_FLOW_CARGO_TARGETS="x86_64-unknown-linux-musl:ubuntu-24.04 x86_64-pc-windows-msvc:windows-latest aarch64-apple-darwin"
  t_run bash "${adapter}" targets
  assert_rc 0 "C2: targets listed"
  assert_eq '[{"target":"x86_64-unknown-linux-musl","runner":"ubuntu-24.04"},{"target":"x86_64-pc-windows-msvc","runner":"windows-latest"},{"target":"aarch64-apple-darwin","runner":"ubuntu-24.04"}]' "${T_OUT}" "C2: targets with runners (default ubuntu-24.04)"
  t_run bash "${ROOT}/scripts/candidate-targets.sh" --adapter "${adapter}"
  assert_rc 0 "C2: candidate-targets accepts the cargo targets"
  t_run bash "${adapter}" inventory "0.2.0"
  assert_rc 0 "C2: inventory succeeds"
  assert_eq "demo-app-0.2.0-x86_64-unknown-linux-musl.tar.gz:x86_64-unknown-linux-musl demo-app-0.2.0-x86_64-pc-windows-msvc.tar.gz:x86_64-pc-windows-msvc demo-app-0.2.0-x86_64-pc-windows-msvc.zip:x86_64-pc-windows-msvc demo-app-0.2.0-aarch64-apple-darwin.tar.gz:aarch64-apple-darwin" \
    "$(printf '%s' "${T_OUT}" | jq -r '[.artifacts[] | .name + ":" + .target] | join(" ")')" "C2: archive per target, plus a Windows zip"
  unset RELEASE_FLOW_CARGO_TARGETS
cd "${orig_pwd}"

t_case "C3: Linux deb and rpm join the inventory when metadata is present"
cd "${crate_dir}"
  cat >> Cargo.toml <<'EOF'

[package.metadata.generate-rpm]
assets = [
    { source = "target/release/demo-app", dest = "/usr/bin/demo-app", mode = "0755" },
]

[package.metadata.deb]
assets = [
  ["target/release/demo-app", "/usr/bin/demo-app", "755"],
]
depends = ""
EOF
  export RELEASE_FLOW_CARGO_TARGETS="x86_64-unknown-linux-musl:ubuntu-24.04 aarch64-apple-darwin:macos-latest"
  t_run bash "${adapter}" inventory "0.2.0"
  assert_rc 0 "C3: inventory succeeds"
  assert_eq "demo-app-0.2.0-x86_64-unknown-linux-musl.tar.gz:x86_64-unknown-linux-musl demo-app-0.2.0-x86_64-unknown-linux-musl.deb:x86_64-unknown-linux-musl demo-app-0.2.0-x86_64-unknown-linux-musl.rpm:x86_64-unknown-linux-musl demo-app-0.2.0-aarch64-apple-darwin.tar.gz:aarch64-apple-darwin" \
    "$(printf '%s' "${T_OUT}" | jq -r '[.artifacts[] | .name + ":" + .target] | join(" ")')" "C3: deb and rpm only on the Linux target"
  unset RELEASE_FLOW_CARGO_TARGETS
cd "${orig_pwd}"

t_finish
