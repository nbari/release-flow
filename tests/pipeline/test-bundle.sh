#!/usr/bin/env bash
# Test the release-flow distribution bundle builder and installer.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

orig_dir="$(pwd)"
bundler="${ROOT}/scripts/release-flow-bundle.sh"

# build_bundle <version> <out-dir> [epoch]: prints archive path
build_bundle() {
  SOURCE_DATE_EPOCH="${3:-1700000000}" bash "${bundler}" --version "$1" --out "$2" 2>/dev/null
}

# extract_bundle <archive> <dir>: prints extracted bundle root
extract_bundle() {
  mkdir -p "$2"
  tar -xzf "$1" -C "$2"
  printf '%s/%s' "$2" "$(basename "$1" .tar.gz)"
}

# rehash <bundle-root> <section> <path>: refresh a BUNDLE.json checksum after editing
rehash() {
  local root="$1" section="$2" path="$3" prefix sum
  if [[ "${section}" == "payload" ]]; then prefix="payload/"; else prefix="optional/"; fi
  sum="$(sha256sum "${root}/${prefix}${path}" | awk '{print $1}')"
  jq --arg s "${section}" --arg p "${path}" --arg h "${sum}" \
    '.[$s] |= map(if .path == $p then .sha256 = $h else . end)' "${root}/BUNDLE.json" > "${root}/BUNDLE.json.tmp"
  mv "${root}/BUNDLE.json.tmp" "${root}/BUNDLE.json"
}

file_sha() {
  sha256sum "$1" | awk '{print $1}'
}

exists() {
  if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

refs_of() {
  git -C "$1" for-each-ref --format='%(refname) %(objectname)' | sort
  git -C "$1" rev-parse HEAD
}

PAYLOAD_PATHS=".github/workflows/candidate.yml
.github/workflows/release.yml
.justfiles/deploy.just
scripts/candidate-guard.sh
scripts/candidate-manifest.sh
scripts/candidate-targets.sh
scripts/lib/common.sh
scripts/lib/github.sh
scripts/lib/project.sh
scripts/lib/schema.sh
scripts/lib/tag.sh
scripts/pipeline-pin.sh
scripts/publication/ci-install-oras.sh
scripts/publication/latest.sh
scripts/publication/ledger.sh
scripts/publication/plan.sh
scripts/publication/publish.sh
scripts/publication/resolve.sh
scripts/publishers/crates-io.sh
scripts/publishers/docs.sh
scripts/publishers/github-release.sh
scripts/publishers/helm.sh
scripts/publishers/oci.sh
scripts/release-deploy.sh
scripts/release-prepare.sh
scripts/release-promote.sh
scripts/release-retry.sh
scripts/release-status.sh
scripts/storage/backends/fs.sh
scripts/storage/backends/s3.sh
scripts/storage/ci-credentials.sh
scripts/storage/storage.sh
scripts/verify-candidate.sh"
PAYLOAD_COUNT=33
SUPPORT_DOCS="docs/MARKETPLACE.md
docs/callers/candidate.yml
docs/callers/release.yml
examples/shell/tools/adapter.sh
examples/shell/VERSION
examples/shell/app/hello.sh
examples/shell/.release-flow.json
docs/ADOPTION.md
docs/RULESETS.md
docs/release-flow.example.json
docs/rulesets/candidates.json
docs/rulesets/develop-integrity.json
docs/rulesets/develop-review.json
docs/rulesets/main-integrity.json
docs/rulesets/main-promotion.json
docs/rulesets/release-tags-create.json
docs/rulesets/release-tags-immutable.json"

t_case "B1: Reproducible bundle archives"
a1="$(build_bundle 9.9.9 "${TF_TMP}/b1-a")"
a2="$(build_bundle 9.9.9 "${TF_TMP}/b1-b")"
assert_eq "${TF_TMP}/b1-a/release-flow-bundle-9.9.9.tar.gz" "${a1}" "B1: archive path printed on stdout"
assert_eq "$(file_sha "${a1}")" "$(file_sha "${a2}")" "B1: identical SOURCE_DATE_EPOCH gives byte-identical archives"
t_run bash "${bundler}" --version 9.9.9 --out "${TF_TMP}/b1-a"
assert_rc 1 "B1: refuses to overwrite an existing archive"
t_run bash "${bundler}" --version 9.9 --out "${TF_TMP}/b1-c"
assert_rc 2 "B1: rejects a non-SemVer version"

t_case "B2: Bundle contents and BUNDLE.json"
expected_files="$(
  {
    printf '%s\n' "release-flow-bundle-9.9.9/BUNDLE.json" "release-flow-bundle-9.9.9/install.sh" \
      "release-flow-bundle-9.9.9/optional/scripts/adapters/cargo.sh"
    printf '%s\n' "${SUPPORT_DOCS}" | sed 's|^|release-flow-bundle-9.9.9/|'
    printf '%s\n' "${PAYLOAD_PATHS}" | sed 's|^|release-flow-bundle-9.9.9/payload/|'
  } | sort
)"
actual_files="$(tar -tzf "${a1}" | grep -v '/$' | sort)"
assert_eq "${expected_files}" "${actual_files}" "B2: archive file set matches the contract"
b2="$(extract_bundle "${a1}" "${TF_TMP}/b2")"
assert_eq "$(git -C "${ROOT}" rev-parse HEAD)" "$(jq -r .source_commit "${b2}/BUNDLE.json")" "B2: source_commit is the source HEAD"
assert_eq "9.9.9" "$(jq -r .bundle_version "${b2}/BUNDLE.json")" "B2: bundle_version recorded"
assert_eq "1.27.0" "$(jq -r .min_just "${b2}/BUNDLE.json")" "B2: min_just recorded"
assert_eq "${PAYLOAD_PATHS}" "$(jq -r '.payload[].path' "${b2}/BUNDLE.json")" "B2: payload paths sorted and complete"
mismatches=0
while IFS=$'\t' read -r p s; do
  [[ "$(file_sha "${b2}/payload/${p}")" == "${s}" ]] || mismatches=$(( mismatches + 1 ))
done <<< "$(jq -r '.payload[] | .path + "\t" + .sha256' "${b2}/BUNDLE.json")"
while IFS=$'\t' read -r p s; do
  [[ "$(file_sha "${b2}/optional/${p}")" == "${s}" ]] || mismatches=$(( mismatches + 1 ))
done <<< "$(jq -r '.optional[] | .path + "\t" + .sha256' "${b2}/BUNDLE.json")"
assert_eq "0" "${mismatches}" "B2: BUNDLE.json checksums match the extracted files"
assert_eq "755" "$(jq -r '.payload[] | select(.path == "scripts/release-deploy.sh") | .mode' "${b2}/BUNDLE.json")" "B2: scripts are mode 755"
assert_eq "644" "$(jq -r '.payload[] | select(.path == ".justfiles/deploy.just") | .mode' "${b2}/BUNDLE.json")" "B2: deploy.just is mode 644"

t_case "B3: Fresh install into a repository"
repo="$(tf_fixture_repo "bundle-fresh")"
refs_before="$(refs_of "${repo}")"
t_run bash "${b2}/install.sh" --target "${repo}"
assert_rc 0 "B3: install succeeds"
assert_contains "${T_OUT}" "bundle_version=9.9.9" "B3: reports bundle version"
assert_contains "${T_OUT}" "installed=${PAYLOAD_COUNT}" "B3: installs every payload file"
assert_contains "${T_ERR}" "import '.justfiles/deploy.just'" "B3: prints the import instruction"
assert_not_contains "${T_ERR}" "release-flow.example.json" "B3: no config instruction when .release-flow.json exists"
missing=0
while IFS= read -r p; do
  [[ -f "${repo}/${p}" ]] || missing=$(( missing + 1 ))
done <<< "${PAYLOAD_PATHS}"
assert_eq "0" "${missing}" "B3: payload files present"
assert_eq "present" "$( [[ -x "${repo}/scripts/release-deploy.sh" ]] && echo present || echo absent)" "B3: scripts executable"
assert_eq "absent" "$( [[ -x "${repo}/.justfiles/deploy.just" ]] && echo present || echo absent)" "B3: deploy.just not executable"
assert_eq "absent" "$(exists "${repo}/scripts/adapters/cargo.sh")" "B3: optional cargo adapter not installed by default"
assert_eq "9.9.9" "$(jq -r .bundle_version "${repo}/.release-flow-bundle.json")" "B3: lock file written"
assert_eq "${refs_before}" "$(refs_of "${repo}")" "B3: no refs or commits created"
assert_eq "" "$(git -C "${repo}" diff --cached --name-only)" "B3: nothing staged"
rm -f "${repo}/.release-flow.json"
t_run bash "${b2}/install.sh" --target "${repo}"
assert_rc 0 "B3: re-install is idempotent"
assert_contains "${T_OUT}" "unchanged=${PAYLOAD_COUNT}" "B3: re-install leaves identical files"
assert_contains "${T_ERR}" "release-flow.example.json" "B3: config instruction when .release-flow.json is missing"
t_run bash "${b2}/install.sh" --target "${repo}/tools"
assert_rc 2 "B3: target must be the work-tree root"
t_run bash "${ROOT}/scripts/release-flow-install.sh" --target "${repo}"
assert_rc 2 "B3: installer outside an extracted bundle is a usage error"
assert_contains "${T_ERR}" "run install.sh from an extracted bundle" "B3: explains where to run install.sh"

t_case "B4: Conflicting unmanaged file"
repo="$(tf_fixture_repo "bundle-conflict")"
mkdir -p "${repo}/scripts"
printf '#!/usr/bin/env bash\necho custom\n' > "${repo}/scripts/release-prepare.sh"
custom_sha="$(file_sha "${repo}/scripts/release-prepare.sh")"
t_run bash "${b2}/install.sh" --target "${repo}"
assert_rc 1 "B4: conflict fails install"
assert_contains "${T_ERR}" "scripts/release-prepare.sh" "B4: names the conflicting path"
assert_eq "${custom_sha}" "$(file_sha "${repo}/scripts/release-prepare.sh")" "B4: conflicting file untouched"
assert_eq "absent" "$(exists "${repo}/.justfiles/deploy.just")" "B4: nothing written"
assert_eq "absent" "$(exists "${repo}/.release-flow-bundle.json")" "B4: no lock written"

t_case "B5: Upgrade"
a_next="$(build_bundle 9.9.10 "${TF_TMP}/b5")"
b5="$(extract_bundle "${a_next}" "${TF_TMP}/b5-x")"
printf '# upgraded\n' >> "${b5}/payload/scripts/release-deploy.sh"
rehash "${b5}" payload scripts/release-deploy.sh
jq '.payload |= map(select(.path != "scripts/verify-candidate.sh"))' "${b5}/BUNDLE.json" > "${b5}/BUNDLE.json.tmp"
mv "${b5}/BUNDLE.json.tmp" "${b5}/BUNDLE.json"
repo="$(tf_fixture_repo "bundle-upgrade")"
bash "${b2}/install.sh" --target "${repo}" >/dev/null 2>&1
t_run bash "${b5}/install.sh" --target "${repo}"
assert_rc 1 "B5: different installed version without --upgrade fails"
assert_contains "${T_ERR}" "already installed 9.9.9" "B5: names installed version"
t_run bash "${b5}/install.sh" --target "${repo}" --upgrade
assert_rc 0 "B5: --upgrade succeeds"
assert_contains "${T_OUT}" "updated=1" "B5: unchanged-by-user file overwritten"
assert_contains "${T_OUT}" "removed=1" "B5: file dropped from the bundle removed"
assert_eq "$(file_sha "${b5}/payload/scripts/release-deploy.sh")" "$(file_sha "${repo}/scripts/release-deploy.sh")" "B5: new content installed"
assert_eq "absent" "$(exists "${repo}/scripts/verify-candidate.sh")" "B5: removed file deleted"
assert_eq "9.9.10" "$(jq -r .bundle_version "${repo}/.release-flow-bundle.json")" "B5: lock updated"
repo="$(tf_fixture_repo "bundle-upgrade-conflict")"
bash "${b2}/install.sh" --target "${repo}" >/dev/null 2>&1
printf '# local change\n' >> "${repo}/scripts/release-deploy.sh"
local_sha="$(file_sha "${repo}/scripts/release-deploy.sh")"
lock_sha="$(file_sha "${repo}/.release-flow-bundle.json")"
t_run bash "${b5}/install.sh" --target "${repo}" --upgrade
assert_rc 1 "B5: locally modified file conflicts on upgrade"
assert_contains "${T_ERR}" "scripts/release-deploy.sh" "B5: names the modified file"
assert_eq "${local_sha}" "$(file_sha "${repo}/scripts/release-deploy.sh")" "B5: modified file untouched"
assert_eq "present" "$(exists "${repo}/scripts/verify-candidate.sh")" "B5: nothing removed on conflict"
assert_eq "${lock_sha}" "$(file_sha "${repo}/.release-flow-bundle.json")" "B5: lock untouched on conflict"

t_case "B6: --check drift detection"
repo="$(tf_fixture_repo "bundle-check")"
bash "${b2}/install.sh" --target "${repo}" >/dev/null 2>&1
t_run bash "${b2}/install.sh" --target "${repo}" --check
assert_rc 0 "B6: clean install passes --check"
assert_contains "${T_OUT}" "drift=0" "B6: reports no drift"
printf '# drift\n' >> "${repo}/scripts/candidate-guard.sh"
drift_sha="$(file_sha "${repo}/scripts/candidate-guard.sh")"
lock_sha="$(file_sha "${repo}/.release-flow-bundle.json")"
t_run bash "${b2}/install.sh" --target "${repo}" --check
assert_rc 1 "B6: drift fails --check"
assert_contains "${T_ERR}" "scripts/candidate-guard.sh" "B6: names the drifted file"
assert_eq "${drift_sha}" "$(file_sha "${repo}/scripts/candidate-guard.sh")" "B6: --check is read-only (file)"
assert_eq "${lock_sha}" "$(file_sha "${repo}/.release-flow-bundle.json")" "B6: --check is read-only (lock)"

t_case "B7: Tampered bundle"
b7="$(extract_bundle "${a1}" "${TF_TMP}/b7")"
printf '# tampered\n' >> "${b7}/payload/scripts/release-prepare.sh"
repo="$(tf_fixture_repo "bundle-tampered")"
t_run bash "${b7}/install.sh" --target "${repo}"
assert_rc 1 "B7: checksum mismatch fails install"
assert_contains "${T_ERR}" "checksum mismatch" "B7: reports checksum mismatch"
assert_eq "absent" "$(exists "${repo}/scripts/release-prepare.sh")" "B7: nothing written"
assert_eq "absent" "$(exists "${repo}/.release-flow-bundle.json")" "B7: no lock written"

t_case "B8: release-flow adapter inventory includes the bundle"
cd "${ROOT}"
t_run "${ROOT}/scripts/adapters/release-flow.sh" inventory 9.9.9
assert_rc 0 "B8: inventory succeeds"
names="$(printf '%s' "${T_OUT}" | jq -r '.artifacts[].name' | tr '\n' ' ')"
assert_contains "${names}" "release-flow-9.9.9-x86_64-unknown-linux-musl.tar.gz" "B8: lists the Linux Cargo archive"
assert_contains "${names}" "release-flow-9.9.9-x86_64-unknown-linux-musl.deb" "B8: lists the Linux deb"
assert_contains "${names}" "release-flow-9.9.9-x86_64-unknown-linux-musl.rpm" "B8: lists the Linux rpm"
assert_contains "${names}" "release-flow-9.9.9-aarch64-unknown-linux-musl.tar.gz" "B8: lists the arm64 Cargo archive"
assert_contains "${names}" "release-flow-9.9.9-x86_64-apple-darwin.tar.gz" "B8: lists the macOS Cargo archive"
assert_contains "${names}" "release-flow-9.9.9-x86_64-pc-windows-msvc.tar.gz" "B8: lists the Windows Cargo archive"
assert_contains "${names}" "release-flow-9.9.9-x86_64-pc-windows-msvc.zip" "B8: lists the Windows zip"
assert_contains "${names}" "release-flow-bundle-9.9.9.tar.gz" "B8: lists the bundle archive"
assert_contains "${names}" "release-flow-9.9.9.crate" "B8: lists the crate package"
t_run "${ROOT}/scripts/adapters/release-flow.sh" targets
assert_rc 0 "B8: targets succeeds"
assert_eq "x86_64-unknown-linux-musl:ubuntu-24.04 aarch64-unknown-linux-musl:ubuntu-24.04-arm x86_64-apple-darwin:macos-latest x86_64-pc-windows-msvc:windows-latest any:ubuntu-24.04" \
  "$(printf '%s' "${T_OUT}" | jq -r 'map(.target + ":" + .runner) | join(" ")')" "B8: one matrix leg per platform plus the any leg"
t_run bash "${ROOT}/scripts/candidate-targets.sh" --adapter scripts/adapters/release-flow.sh
assert_rc 0 "B8: candidate-targets accepts the release-flow targets"
RELEASE_FLOW_TARGETS="any" t_run "${ROOT}/scripts/adapters/release-flow.sh" inventory 9.9.9
assert_eq "release-flow-bundle-9.9.9.tar.gz:any release-flow-9.9.9.crate:any" \
  "$(printf '%s' "${T_OUT}" | jq -r '[.artifacts[] | .name + ":" + .target] | join(" ")')" "B8: RELEASE_FLOW_TARGETS filters the inventory"
t_run "${ROOT}/scripts/adapters/release-flow.sh" bogus
assert_rc 2 "B8: unknown subcommand is a usage error"
cd "${orig_dir}"

t_case "B9: Optional Cargo adapter install and upgrade"
repo="$(tf_fixture_repo "bundle-cargo")"
lock="${repo}/.release-flow-bundle.json"
t_run bash "${b2}/install.sh" --target "${repo}" --with-cargo-adapter
assert_rc 0 "B9: --with-cargo-adapter install succeeds"
assert_contains "${T_OUT}" "installed=$(( PAYLOAD_COUNT + 1 ))" "B9: installs payload plus the cargo adapter"
assert_eq "$(file_sha "${b2}/optional/scripts/adapters/cargo.sh")" "$(file_sha "${repo}/scripts/adapters/cargo.sh")" "B9: cargo adapter content installed"
assert_eq "present" "$( [[ -x "${repo}/scripts/adapters/cargo.sh" ]] && echo present || echo absent)" "B9: cargo adapter executable"
assert_eq "$(jq -r '.optional[] | select(.path == "scripts/adapters/cargo.sh") | .sha256' "${b2}/BUNDLE.json")" \
  "$(jq -r '.files[] | select(.path == "scripts/adapters/cargo.sh") | .sha256' "${lock}")" "B9: cargo adapter recorded in the lock"
t_run bash "${b5}/install.sh" --target "${repo}" --upgrade
assert_rc 0 "B9: --upgrade without --with-cargo-adapter succeeds"
assert_eq "present" "$(exists "${repo}/scripts/adapters/cargo.sh")" "B9: --upgrade keeps the installed cargo adapter"
assert_eq "scripts/adapters/cargo.sh" "$(jq -r '.files[] | select(.path == "scripts/adapters/cargo.sh") | .path' "${lock}")" "B9: upgraded lock still records the cargo adapter"
assert_eq "9.9.10" "$(jq -r .bundle_version "${lock}")" "B9: lock upgraded"
t_run bash "${b5}/install.sh" --target "${repo}" --check
assert_rc 0 "B9: --check passes after upgrade"
assert_contains "${T_OUT}" "checked=${PAYLOAD_COUNT}" "B9: --check covers the cargo adapter (payload minus the file 9.9.10 dropped)"

t_case "B10: Symlinked or non-regular destinations"
repo="$(tf_fixture_repo "bundle-symlink-parent")"
outside="${TF_TMP}/b10-outside"
mkdir -p "${outside}"
ln -s "${outside}" "${repo}/scripts"
t_run bash "${b2}/install.sh" --target "${repo}"
assert_rc 1 "B10: symlinked parent directory fails install"
assert_contains "${T_ERR}" "scripts/release-prepare.sh: parent scripts is a symlink or not a directory" "B10: names the symlinked parent"
assert_eq "" "$(ls -A "${outside}")" "B10: nothing written through the symlink"
assert_eq "absent" "$(exists "${repo}/.justfiles/deploy.just")" "B10: nothing written"
assert_eq "absent" "$(exists "${repo}/.release-flow-bundle.json")" "B10: no lock written"

repo="$(tf_fixture_repo "bundle-symlink-upgrade")"
bash "${b2}/install.sh" --target "${repo}" >/dev/null 2>&1
moved="${TF_TMP}/b10-moved-scripts"
mv "${repo}/scripts" "${moved}"
ln -s "${moved}" "${repo}/scripts"
lock_sha="$(file_sha "${repo}/.release-flow-bundle.json")"
t_run bash "${b5}/install.sh" --target "${repo}" --upgrade
assert_rc 1 "B10: symlinked parent fails upgrade"
assert_contains "${T_ERR}" "scripts/verify-candidate.sh: parent scripts" "B10: names the removal through the symlink"
assert_eq "present" "$(exists "${moved}/verify-candidate.sh")" "B10: nothing deleted through the symlink"
assert_eq "$(file_sha "${b2}/payload/scripts/release-deploy.sh")" "$(file_sha "${moved}/release-deploy.sh")" "B10: nothing overwritten through the symlink"
assert_eq "${lock_sha}" "$(file_sha "${repo}/.release-flow-bundle.json")" "B10: lock untouched"
t_run bash "${b2}/install.sh" --target "${repo}" --check
assert_rc 1 "B10: --check reports a symlinked parent as drift"
assert_contains "${T_ERR}" "drift: scripts/candidate-guard.sh (parent scripts" "B10: --check names the symlinked parent"

repo="$(tf_fixture_repo "bundle-symlink-file")"
bash "${b2}/install.sh" --target "${repo}" >/dev/null 2>&1
cp -p "${repo}/scripts/candidate-guard.sh" "${TF_TMP}/b10-guard.sh"
rm "${repo}/scripts/candidate-guard.sh"
ln -s "${TF_TMP}/b10-guard.sh" "${repo}/scripts/candidate-guard.sh"
t_run bash "${b2}/install.sh" --target "${repo}" --check
assert_rc 1 "B10: --check rejects a symlinked managed file with identical content"
assert_contains "${T_ERR}" "drift: scripts/candidate-guard.sh (symlink)" "B10: --check names the symlinked file"

for kind in directory symlink; do
  repo="$(tf_fixture_repo "bundle-lock-${kind}")"
  if [[ "${kind}" == "directory" ]]; then
    lock_target="${repo}/.release-flow-bundle.json"
    mkdir "${lock_target}"
  else
    lock_target="${TF_TMP}/b10-lock-target"
    mkdir "${lock_target}"
    ln -s "${lock_target}" "${repo}/.release-flow-bundle.json"
  fi
  t_run bash "${b2}/install.sh" --target "${repo}"
  assert_rc 1 "B10: lock path ${kind} fails install"
  assert_contains "${T_ERR}" "conflict: .release-flow-bundle.json: exists and is not a regular file" "B10: lock path ${kind} reported as conflict"
  assert_eq "absent" "$(exists "${repo}/scripts/release-prepare.sh")" "B10: lock path ${kind}: nothing written"
  assert_eq "" "$(ls -A "${lock_target}")" "B10: lock path ${kind}: nothing written into the lock path"
  t_run bash "${b2}/install.sh" --target "${repo}" --check
  assert_rc 1 "B10: lock path ${kind} fails --check"
done

t_case "B11: release-flow adapter package builds the Cargo archive and the bundle"
src="${TF_TMP}/b11-src"
for f in action.yml scripts/action.sh scripts/adapters/release-flow.sh scripts/adapters/cargo.sh scripts/release-flow-bundle.sh \
  scripts/release-flow-install.sh ${PAYLOAD_PATHS} ${SUPPORT_DOCS}; do
  mkdir -p "$(dirname "${src}/${f}")"
  cp -p "${ROOT}/${f}" "${src}/${f}"
done
mkdir -p "${src}/src"
cat <<'EOF' > "${src}/Cargo.toml"
[package]
name = "demo-app"
version = "0.3.0"
edition = "2024"

[[bin]]
name = "demo-app"
path = "src/main.rs"
EOF
printf 'fn main() {\n    println!("demo app");\n}\n' > "${src}/src/main.rs"
printf 'target/\n' > "${src}/.gitignore"
cd "${src}"
cargo generate-lockfile --quiet
git init --quiet
git add .
git commit -m "B11 source" --quiet
dist="${TF_TMP}/b11-dist"
host_target="$(rustc -vV | awk '/^host:/ {print $2}')"
export RELEASE_FLOW_CARGO_TARGETS="${host_target}"
SOURCE_DATE_EPOCH=1700000000 t_run "${src}/scripts/adapters/release-flow.sh" package 0.3.0 "${dist}"
assert_rc 0 "B11: package succeeds"
expected_names="$("${src}/scripts/adapters/release-flow.sh" inventory 0.3.0 | jq -r '.artifacts[].name' | sort)"
assert_contains "${expected_names}" "demo-app-0.3.0-${host_target}.tar.gz" "B11: Cargo archive for the configured target"
assert_contains "${expected_names}" "demo-app-0.3.0.crate" "B11: crate package is an inventory artifact"
assert_eq "demo-app-0.3.0/Cargo.toml" "$(tar -tzf "${dist}/demo-app-0.3.0.crate" 2>/dev/null | grep -x 'demo-app-0.3.0/Cargo.toml' || true)" "B11: crate package holds the manifest"
rm -rf "${TF_TMP}/b11-any"
RELEASE_FLOW_TARGET=any SOURCE_DATE_EPOCH=1700000000 t_run "${src}/scripts/adapters/release-flow.sh" package 0.3.0 "${TF_TMP}/b11-any"
assert_rc 0 "B11: the any leg packages"
assert_eq "demo-app-0.3.0.crate release-flow-bundle-0.3.0.tar.gz" "$(find "${TF_TMP}/b11-any" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' ' | sed 's/ $//')" "B11: the any leg builds only platform-independent artifacts"
assert_eq "${expected_names}" "$(find "${dist}" -maxdepth 1 -type f -printf '%f\n' | sort)" "B11: package produces exactly the inventory artifacts"
assert_contains "${expected_names}" "release-flow-bundle-0.3.0.tar.gz" "B11: bundle is an inventory artifact"
b11="$(extract_bundle "${dist}/release-flow-bundle-0.3.0.tar.gz" "${TF_TMP}/b11-x")"
assert_eq "0.3.0" "$(jq -r .bundle_version "${b11}/BUNDLE.json")" "B11: bundle carries the package version"
assert_eq "$(git rev-parse HEAD)" "$(jq -r .source_commit "${b11}/BUNDLE.json")" "B11: bundle built from the source HEAD"
t_run "${src}/scripts/adapters/release-flow.sh" package 0.3.0
assert_rc 2 "B11: missing outdir is a usage error"
SOURCE_DATE_EPOCH=1700000000 t_run "${src}/scripts/adapters/release-flow.sh" package 0.3.0 "${dist}"
assert_rc 1 "B11: refuses a non-empty output directory"
unset RELEASE_FLOW_CARGO_TARGETS
cd "${orig_dir}"

t_case "B12: Malformed BUNDLE.json"
n=0
for filter in 'del(.optional)' '.payload = {}' '.payload[0].mode = "777"' 'del(.payload[0].path)'; do
  n=$(( n + 1 ))
  b12="$(extract_bundle "${a1}" "${TF_TMP}/b12-${n}")"
  jq "${filter}" "${b12}/BUNDLE.json" > "${b12}/BUNDLE.json.tmp"
  mv "${b12}/BUNDLE.json.tmp" "${b12}/BUNDLE.json"
  repo="$(tf_fixture_repo "bundle-malformed-${n}")"
  t_run bash "${b12}/install.sh" --target "${repo}"
  assert_rc 1 "B12 '${filter}': rejected"
  assert_contains "${T_ERR}" "Unsupported or invalid BUNDLE.json" "B12 '${filter}': explains invalid manifest"
  assert_eq "absent" "$(exists "${repo}/.release-flow-bundle.json")" "B12 '${filter}': no lock written"
  assert_eq "absent" "$(exists "${repo}/.justfiles/deploy.just")" "B12 '${filter}': nothing written"
done

t_case "B13: Reusable bundles pin callers and configuration to clean source"
source_repo="${TF_TMP}/bundle-source"
git init --quiet "${source_repo}"
for path in scripts docs examples .github .justfiles; do
  cp -R "${ROOT}/${path}" "${source_repo}/${path}"
done
cp "${ROOT}/action.yml" "${source_repo}/action.yml"
git -C "${source_repo}" add .
git -C "${source_repo}" commit --quiet -m "Record bundle sources"
source_sha="$(git -C "${source_repo}" rev-parse HEAD)"
t_run bash "${source_repo}/scripts/release-flow-bundle.sh" --version 9.9.8 --out "${TF_TMP}/reusable-out" --workflow-mode reusable
assert_rc 0 "B13: clean reusable bundle builds"
reusable="$(extract_bundle "${T_OUT}" "${TF_TMP}/reusable-extract")"
assert_contains "$(cat "${reusable}/payload/.github/workflows/candidate.yml")" "candidate.yml@${source_sha}" "B13: candidate pinned"
assert_contains "$(cat "${reusable}/payload/.github/workflows/release.yml")" "release.yml@${source_sha}" "B13: release pinned"
assert_eq "${source_sha}" "$(jq -r .pipeline.sha "${reusable}/docs/release-flow.example.json")" "B13: example pin matches"
assert_eq reusable "$(jq -r .workflow_mode "${reusable}/BUNDLE.json")" "B13: mode recorded"
repo="$(tf_fixture_repo bundle-reusable)"
t_run bash "${reusable}/install.sh" --target "${repo}"
assert_rc 0 "B13: installs"
assert_contains "${T_ERR}" "pipeline.sha=${source_sha}" "B13: explains config upgrade"
t_run bash "${reusable}/install.sh" --target "${repo}"
assert_rc 0 "B13: idempotent install"
t_run bash "${reusable}/install.sh" --target "${repo}" --check
assert_rc 0 "B13: checks rendered checksums"
printf '\n# dirty\n' >> "${source_repo}/scripts/lib/common.sh"
t_run bash "${source_repo}/scripts/release-flow-bundle.sh" --version 9.9.7 --out "${TF_TMP}/dirty-out" --workflow-mode reusable
assert_rc 1 "B13: dirty source cannot claim pinned runtime"

t_case "B14: Installer temporary files cannot follow planted symlinks"
repo="$(tf_fixture_repo bundle-temp-link)"
outside="${TF_TMP}/outside-installer"
printf 'preserve outside bytes\n' > "${outside}"
mkdir -p "${repo}/scripts"
# The inner shell must expand its own PID for the attack reproduction.
# shellcheck disable=SC2016
t_run bash -c '
  ln -s "$3" "$2/scripts/release-deploy.sh.release-flow-tmp.$$"
  ln -s "$3" "$2/.release-flow-bundle.json.tmp.$$"
  exec bash "$1/install.sh" --target "$2"
' _ "${b2}" "${repo}" "${outside}"
assert_rc 0 "B14: install succeeds without using predictable paths"
assert_eq 'preserve outside bytes' "$(cat "${outside}")" "B14: never writes through temporary symlink"
assert_eq regular "$([[ ! -L "${repo}/scripts/release-deploy.sh" ]] && echo regular || echo symlink)" "B14: managed destination stays regular"

t_finish
