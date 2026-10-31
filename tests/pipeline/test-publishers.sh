#!/usr/bin/env bash
# Independent, recoverable publication (scripts/publication/publish.sh and
# scripts/publishers/*): GitHub Release drafts and resume, OCI by digest with a
# forward-only latest, crates.io byte identity, docs and Helm targets, digest
# and source failures. Never rebuilds, never retags.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/pipeline/lib-release.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-release.sh"

tf_mock_tools_on

out_kv() {
  printf '%s\n' "${T_OUT}" | sed -n "s/^$1=//p"
}

exists() {
  if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

publish() {
  local repo="$1" version="$2" channel="$3"
  t_run bash "${repo}/scripts/publication/publish.sh" --project-dir "${repo}" --version "${version}" --channel "${channel}"
}

# ledger_state <name> <version> <channel> <field>
ledger_field() {
  bash "${ROOT}/scripts/publication/ledger.sh" --uri "file://$(tf_store "$1")" status --project "$1" --version "$2" --channel "$3" \
    | jq -r --arg c "$3" ".channels[\$c].$4"
}

ledger_attempts() {
  bash "${ROOT}/scripts/storage/storage.sh" --uri "file://$(tf_store "$1")" list "ledger/$1/$2/$3/" | awk -F/ '{print $5}' | sort -u | grep -c . || true
}

# attempt_field <name> <version> <channel> <attempt> <field>: <field> of the
# last ledger event of one attempt
attempt_field() {
  local key
  key="$(bash "${ROOT}/scripts/storage/storage.sh" --uri "file://$(tf_store "$1")" list "ledger/$1/$2/$3/$4/" \
    | LC_ALL=C sort | tail -n 1)"
  jq -r ".$5" "$(tf_store "$1")/${key}"
}

# release_dir <name> <version>: the mock GitHub release directory
release_dir() {
  local d
  for d in "${MOCK_GH_ROOT}/releases/acme_$1"/*/; do
    [[ -f "${d}meta.json" ]] || continue
    if [[ "$(jq -r .tag_name "${d}meta.json")" == "$2" ]]; then
      printf '%s' "${d%/}"
      return 0
    fi
  done
  return 1
}

release_assets() {
  (cd "$1/assets" && for f in *; do printf '%s %s\n' "${f}" "$(sha256sum "${f}" | awk '{print $1}')"; done)
}

desired_assets() {
  (cd "${TF_DIST}" && for f in *; do printf '%s %s\n' "${f}" "$(sha256sum "${f}" | awk '{print $1}')"; done)
}

gh_writes() {
  tf_gh_calls | grep -E '^gh release (create|upload|delete-asset|edit)' || true
}

reset_gh_calls() {
  : > "${MOCK_GH_ROOT}/calls.log"
}

oci_digest() {
  tar -xOf "${TF_DIST}/stub-${TF_V}-oci.tar" index.json | jq -r '.manifests[0].digest'
}

registry_tag() {
  cat "${MOCK_REGISTRY}/ghcr.io_acme_$1/tags/$2" 2>/dev/null || echo absent
}

line_count() {
  if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

# ---------------------------------------------------------------------------

t_case "PB01: GitHub Release happy path"
repo="$(tf_release_repo pb01)"
tf_promoted_release "${repo}" patch
remote_before="$(tf_remote_refs "${TF_TMP}/pb01.git")"
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB01: publish succeeds"
assert_eq "succeeded" "$(out_kv state)" "PB01: reports succeeded"
rel="$(release_dir pb01 0.1.1 || true)"
assert_eq "false" "$(jq -r .draft "${rel}/meta.json" 2>/dev/null)" "PB01: release published (not a draft)"
assert_eq "$(desired_assets)" "$(release_assets "${rel}")" "PB01: assets are the manifest artifacts, SHA256SUMS and manifest.json, byte-identical"
assert_contains "$(tf_gh_calls)" "release create 0.1.1 --repo acme/pb01 --draft --verify-tag" "PB01: created as a draft of the existing tag"
assert_contains "$(tf_gh_calls)" "--draft=false --latest=true" "PB01: published as latest"
assert_eq "${rel##*/}" "$(cat "${MOCK_GH_ROOT}/latest/acme_pb01")" "PB01: GitHub latest is 0.1.1"
assert_not_contains "$(tf_gh_calls)" "--clobber" "PB01: never clobbers assets"
assert_eq "${remote_before}" "$(tf_remote_refs "${TF_TMP}/pb01.git")" "PB01: no tag or branch pushed"
assert_eq "succeeded" "$(ledger_field pb01 0.1.1 github-release state)" "PB01: ledger shows succeeded"
assert_contains "$(jq -r .body "${rel}/meta.json")" "${TF_M}" "PB01: notes pin the manifest digest"

t_case "PB02: Resume a partial draft"
repo="$(tf_release_repo pb02)"
tf_promoted_release "${repo}" patch
printf 'notes\n' > "${TF_TMP}/pb02-notes"
gh release create 0.1.1 --repo acme/pb02 --draft --title 0.1.1 --notes-file "${TF_TMP}/pb02-notes" >/dev/null
gh release upload 0.1.1 "${TF_DIST}/stub-0.1.1-any.txt" --repo acme/pb02
printf 'wrong bytes\n' > "${TF_TMP}/stub-0.1.1.crate"
gh release upload 0.1.1 "${TF_TMP}/stub-0.1.1.crate" --repo acme/pb02
printf 'stray\n' > "${TF_TMP}/stray.bin"
gh release upload 0.1.1 "${TF_TMP}/stray.bin" --repo acme/pb02
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB02: resume succeeds"
rel="$(release_dir pb02 0.1.1)"
assert_eq "$(desired_assets)" "$(release_assets "${rel}")" "PB02: final assets exact"
assert_eq "false" "$(jq -r .draft "${rel}/meta.json")" "PB02: published"
assert_contains "$(tf_gh_calls)" "release delete-asset 0.1.1 stub-0.1.1.crate" "PB02: wrong-digest asset deleted"
assert_contains "$(tf_gh_calls)" "release delete-asset 0.1.1 stray.bin" "PB02: stray asset deleted"
assert_not_contains "$(tf_gh_calls)" "upload 0.1.1 ${TF_TMP}" "PB02: nothing uploaded from outside the release"
assert_not_contains "$(tf_gh_calls)" "release create" "PB02: no second release create"
assert_eq "0" "$(tf_gh_calls | grep -c 'upload .*stub-0.1.1-any.txt' || true)" "PB02: correct asset not re-uploaded"

t_case "PB03: Upload failure, rerun only this channel"
repo="$(tf_release_repo pb03)"
tf_promoted_release "${repo}" patch
oras_before="$(line_count "${MOCK_REGISTRY}/calls.log")"
cargo_before="$(line_count "${MOCK_CARGO_LOG}")"
rm -f "${MOCK_GH_ROOT}/upload-count"
MOCK_GH_FAULT=upload-fail:2 publish "${repo}" 0.1.1 github-release
assert_rc 1 "PB03: upload failure exits 1"
assert_eq "failed" "$(ledger_field pb03 0.1.1 github-release state)" "PB03: ledger failed"
assert_eq "transient" "$(ledger_field pb03 0.1.1 github-release error_class)" "PB03: transient error"
assert_eq "true" "$(jq -r .draft "$(release_dir pb03 0.1.1)/meta.json")" "PB03: release stays a draft"
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB03: rerun of the channel succeeds"
assert_eq "succeeded" "$(ledger_field pb03 0.1.1 github-release state)" "PB03: ledger succeeded"
assert_eq "$(desired_assets)" "$(release_assets "$(release_dir pb03 0.1.1)")" "PB03: assets complete"
assert_eq "github-release" "$(bash "${ROOT}/scripts/storage/storage.sh" --uri "file://$(tf_store pb03)" list ledger/pb03/0.1.1/ | awk -F/ '{print $4}' | sort -u | tr '\n' ' ' | sed 's/ $//')" "PB03: other channels untouched"
assert_eq "${oras_before}" "$(line_count "${MOCK_REGISTRY}/calls.log")" "PB03: oras never called"
assert_eq "${cargo_before}" "$(line_count "${MOCK_CARGO_LOG}")" "PB03: cargo never called"

t_case "PB04: Already published"
repo="$(tf_release_repo pb04)"
tf_promoted_release "${repo}" patch
publish "${repo}" 0.1.1 github-release
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB04: identical published release exits 0"
assert_eq "succeeded" "$(out_kv state)" "PB04: succeeded"
assert_eq "" "$(gh_writes)" "PB04: no write calls"
assert_contains "$(tf_gh_calls)" "gh api --paginate repos/acme/pb04/releases?per_page=100" "PB04: releases are listed across every page"
rel="$(release_dir pb04 0.1.1)"
printf 'swapped\n' > "${rel}/assets/stub-0.1.1-any.txt"
before="$(release_assets "${rel}")"
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 5 "PB04: mismatched published asset exits 5"
failed_attempt="$(out_kv attempt_id)"
assert_eq "failed conflict" "$(attempt_field pb04 0.1.1 github-release "${failed_attempt}" state) $(attempt_field pb04 0.1.1 github-release "${failed_attempt}" error_class)" "PB04: the attempt is recorded failed(conflict)"
assert_eq "succeeded" "$(ledger_field pb04 0.1.1 github-release state)" "PB04: the channel stays succeeded"
assert_eq "${before}" "$(release_assets "${rel}")" "PB04: published release not modified"
assert_eq "" "$(gh_writes)" "PB04: no write calls on conflict"

t_case "PB05: Digest mismatch refused"
repo="$(tf_release_repo pb05a)"
tf_promoted_release "${repo}" patch
printf 'tampered\n' > "$(tf_blob_path pb05a "$(tf_artifact_sha stub-0.1.1-any.txt)")"
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 6 "PB05 tampered blob: exit 6"
assert_eq "integrity" "$(ledger_field pb05a 0.1.1 github-release error_class)" "PB05 tampered blob: failed(integrity)"
assert_eq "" "$(gh_writes)" "PB05 tampered blob: no GitHub writes"
assert_eq "absent" "$(exists "$(release_dir pb05a 0.1.1 || true)/meta.json")" "PB05 tampered blob: no draft"
repo="$(tf_release_repo pb05b)"
tf_promoted_release "${repo}" patch
rec="$(tf_store pb05b)/candidates/pb05b/${TF_C}/${TF_RUN}-1.json"
jq --arg m "$(printf 'other' | sha256sum | awk '{print $1}')" '.manifest_sha256 = $m' "${rec}" > "${rec}.tmp" && mv "${rec}.tmp" "${rec}"
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 6 "PB05 record differs from the tag: exit 6"
assert_contains "${T_ERR}" "differs from tag 0.1.1" "PB05 record differs: explains"
assert_eq "" "$(gh_writes)" "PB05 record differs: no GitHub writes"

t_case "PB06: Source expired from storage"
repo="$(tf_release_repo pb06)"
tf_promoted_release "${repo}" patch
rm -f "$(tf_blob_path pb06 "$(tf_artifact_sha stub-0.1.1.crate)")"
packages_before="$(grep -c '^package$' "${STUB_LOG}" || true)"
cargo_before="$(line_count "${MOCK_CARGO_LOG}")"
MOCK_CARGO_INDEX="${TF_TMP}/pb06-index" publish "${repo}" 0.1.1 crates-io
assert_rc 4 "PB06: missing source exits 4"
assert_eq "missing-source" "$(ledger_field pb06 0.1.1 crates-io error_class)" "PB06: failed(missing-source)"
assert_contains "${T_ERR}" "will not be rebuilt" "PB06: says it will not be rebuilt"
assert_eq "${packages_before}" "$(grep -c '^package$' "${STUB_LOG}" || true)" "PB06: nothing packaged"
assert_eq "${cargo_before}" "$(line_count "${MOCK_CARGO_LOG}")" "PB06: cargo never called"

t_case "PB07: OCI"
repo="$(tf_release_repo pb07)"
tf_promoted_release "${repo}" patch
d1="$(oci_digest)"
publish "${repo}" 0.1.1 oci
assert_rc 0 "PB07: OCI publish succeeds"
assert_eq "present" "$(exists "${MOCK_REGISTRY}/ghcr.io_acme_pb07/manifests/${d1}")" "PB07: pushed by digest"
assert_eq "${d1}" "$(registry_tag pb07 0.1.1)" "PB07: version tag points at the digest"
assert_eq "${d1}" "$(registry_tag pb07 latest)" "PB07: latest points at the digest"
assert_eq "0.1.1" "$(jq -r .version "$(tf_store pb07)/pointers/pb07/oci/latest.json")" "PB07: latest pointer stored"
calls_before="$(line_count "${MOCK_REGISTRY}/calls.log")"
publish "${repo}" 0.1.1 oci
assert_rc 0 "PB07: rerun succeeds"
assert_eq "" "$(tail -n +"$(( calls_before + 1 ))" "${MOCK_REGISTRY}/calls.log" | grep -v '^oras manifest fetch' || true)" "PB07: rerun only fetches"
repo="$(tf_release_repo pb07b)"
tf_promoted_release "${repo}" patch
mkdir -p "${MOCK_REGISTRY}/ghcr.io_acme_pb07b/manifests" "${MOCK_REGISTRY}/ghcr.io_acme_pb07b/tags"
other_d="sha256:$(printf 'other image' | sha256sum | awk '{print $1}')"
printf '{}' > "${MOCK_REGISTRY}/ghcr.io_acme_pb07b/manifests/${other_d}"
printf '%s\n' "${other_d}" > "${MOCK_REGISTRY}/ghcr.io_acme_pb07b/tags/0.1.1"
publish "${repo}" 0.1.1 oci
assert_rc 5 "PB07: version tag at another digest exits 5"
assert_eq "${other_d}" "$(registry_tag pb07b 0.1.1)" "PB07: conflicting tag untouched"
assert_eq "absent" "$(registry_tag pb07b latest)" "PB07: latest not moved on conflict"

t_case "PB08: OCI fails while GitHub Release succeeded"
repo="$(tf_release_repo pb08)"
tf_promoted_release "${repo}" patch
d1="$(oci_digest)"
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB08: github-release succeeds"
MOCK_ORAS_FAULT=cp-fail publish "${repo}" 0.1.1 oci
assert_rc 1 "PB08: OCI fails"
assert_eq "failed" "$(ledger_field pb08 0.1.1 oci state)" "PB08: OCI ledger failed"
t_run bash "${repo}/scripts/release-retry.sh" --project-dir "${repo}" 0.1.1 oci --local
assert_rc 0 "PB08: release-retry --local succeeds"
assert_contains "${T_OUT}" "mode=local" "PB08: local mode"
assert_contains "${T_OUT}" "state=succeeded" "PB08: retry succeeded"
assert_eq "${d1}" "$(registry_tag pb08 0.1.1)" "PB08: the original digest is published"
assert_eq "1" "$(ledger_attempts pb08 0.1.1 github-release)" "PB08: github-release still has exactly one attempt"
assert_eq "succeeded" "$(ledger_field pb08 0.1.1 github-release state)" "PB08: github-release still succeeded"

t_case "PB09: A late older publisher cannot roll back latest"
repo="$(tf_release_repo pb09)"
tf_promoted_release "${repo}" patch
d1="$(oci_digest)"
rm -f "${MOCK_REGISTRY}/held-latest" "${MOCK_REGISTRY}/release-latest"
(
  rc=0
  MOCK_ORAS_HOLD=latest bash "${repo}/scripts/publication/publish.sh" --project-dir "${repo}" --version 0.1.1 --channel oci \
    > "${TF_TMP}/pb09-old.out" 2> "${TF_TMP}/pb09-old.err" || rc=$?
  echo "${rc}" > "${TF_TMP}/pb09-old.rc"
) &
old_pid=$!
for _ in $(seq 1 300); do [[ -e "${MOCK_REGISTRY}/held-latest" ]] && break; sleep 0.1; done
assert_eq "present" "$(exists "${MOCK_REGISTRY}/held-latest")" "PB09: 0.1.1 is held before writing latest"
assert_eq "0.1.1" "$(jq -r .version "$(tf_store pb09)/pointers/pb09/oci/latest.json" 2>/dev/null)" "PB09: 0.1.1 already moved the pointer"
tf_promoted_release "${repo}" patch
d2="$(oci_digest)"
publish "${repo}" 0.1.2 oci
assert_rc 0 "PB09: 0.1.2 OCI publish succeeds"
touch "${MOCK_REGISTRY}/release-latest"
wait "${old_pid}" || true
assert_eq "0" "$(cat "${TF_TMP}/pb09-old.rc")" "PB09: the late 0.1.1 publisher completes"
assert_eq "${d2}" "$(registry_tag pb09 latest)" "PB09: latest is 0.1.2's digest"
assert_eq "0.1.2" "$(jq -r .version "$(tf_store pb09)/pointers/pb09/oci/latest.json")" "PB09: pointer stays at 0.1.2"
assert_eq "${d1}" "$(registry_tag pb09 0.1.1)" "PB09: 0.1.1 version tag exists"
mkdir -p "${TF_TMP}/pb09-docs"
jq -n --arg m "${TF_M}" '{schema_version: 1, kind: "latest-pointer", project: "pb09", channel: "docs", version: "0.1.2", digest: $m, manifest_sha256: $m}' \
  > "${TF_TMP}/pb09-docs/latest.json"
docs_latest_before="$(sha256sum "${TF_TMP}/pb09-docs/latest.json")"
publish "${repo}" 0.1.1 docs
assert_rc 0 "PB09: 0.1.1 docs publish succeeds"
assert_eq "${docs_latest_before}" "$(sha256sum "${TF_TMP}/pb09-docs/latest.json")" "PB09: docs latest.json unchanged"
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB09: 0.1.1 GitHub Release succeeds"
assert_contains "$(tf_gh_calls)" "edit 0.1.1 --repo acme/pb09 --draft=false --latest=false" "PB09: 0.1.1 GitHub Release is not latest"

t_case "PB10: crates.io"
repo="$(tf_release_repo pb10)"
export MOCK_CARGO_INDEX="${TF_TMP}/pb10-index"
idx="${MOCK_CARGO_INDEX}/st/ub/stub"
tf_promoted_release "${repo}" patch
crate_sha="$(tf_artifact_sha stub-0.1.1.crate)"
cargo_before="$(line_count "${MOCK_CARGO_LOG}")"
publish "${repo}" 0.1.1 crates-io
assert_rc 0 "PB10: crates.io publish succeeds"
assert_contains "$(tail -n +"$(( cargo_before + 1 ))" "${MOCK_CARGO_LOG}")" "cargo package --locked --no-verify" "PB10: repackaged at the candidate commit"
assert_contains "$(tail -n +"$(( cargo_before + 1 ))" "${MOCK_CARGO_LOG}")" "cargo publish --locked --no-verify" "PB10: published"
assert_eq "2" "$(tail -n +"$(( cargo_before + 1 ))" "${MOCK_CARGO_LOG}" | grep -c -- "--package stub --index file://${TF_TMP}/pb10-index" || true)" "PB10: package and publish name the package and the configured index"
assert_eq "${crate_sha}" "$(jq -r 'select(.vers == "0.1.1") | .cksum' "${idx}")" "PB10: index cksum equals the manifest digest"
assert_eq "succeeded" "$(ledger_field pb10 0.1.1 crates-io state)" "PB10: ledger succeeded"
assert_eq "" "$(git -C "${repo}" worktree list --porcelain | grep '^worktree ' | grep -v "${repo}$" || true)" "PB10: source worktree removed"
tf_promoted_release "${repo}" patch
cargo_before="$(line_count "${MOCK_CARGO_LOG}")"
MOCK_CARGO_FAULT=package-differs publish "${repo}" 0.1.2 crates-io
assert_rc 5 "PB10: differing repackage exits 5"
assert_contains "${T_ERR}" "repackaged crate differs from validated bytes" "PB10: explains the byte difference"
assert_not_contains "$(tail -n +"$(( cargo_before + 1 ))" "${MOCK_CARGO_LOG}")" "cargo publish" "PB10: cargo publish never ran"
tf_promoted_release "${repo}" patch
jq -nc --arg c "$(tf_artifact_sha stub-0.1.3.crate)" '{name: "stub", vers: "0.1.3", cksum: $c}' >> "${idx}"
cargo_before="$(line_count "${MOCK_CARGO_LOG}")"
publish "${repo}" 0.1.3 crates-io
assert_rc 0 "PB10: already indexed with the same cksum succeeds"
assert_eq "${cargo_before}" "$(line_count "${MOCK_CARGO_LOG}")" "PB10: no cargo call when already published"
tf_promoted_release "${repo}" patch
jq -nc '{name: "stub", vers: "0.1.4", cksum: "0000000000000000000000000000000000000000000000000000000000000000"}' >> "${idx}"
publish "${repo}" 0.1.4 crates-io
assert_rc 5 "PB10: indexed with a different cksum exits 5"
assert_eq "conflict" "$(ledger_field pb10 0.1.4 crates-io error_class)" "PB10: failed(conflict)"
tf_promoted_release "${repo}" patch
MOCK_CARGO_FAULT=already-uploaded publish "${repo}" 0.1.5 crates-io
assert_rc 0 "PB10: 'already uploaded' is settled by the index"
assert_contains "${T_ERR}" "is already uploaded; checking the index" "PB10: explains the already-uploaded path"
assert_eq "succeeded" "$(ledger_field pb10 0.1.5 crates-io state)" "PB10: already uploaded with the same cksum is succeeded"
tf_promoted_release "${repo}" patch
MOCK_CARGO_FAULT=publish-fail publish "${repo}" 0.1.6 crates-io
assert_rc 1 "PB10: any other publish error is transient"
assert_eq "transient" "$(ledger_field pb10 0.1.6 crates-io error_class)" "PB10: failed(transient)"

t_case "PB11: Helm and docs targets"
repo="$(tf_release_repo pb11)"
tf_promoted_release "${repo}" patch
chart_sha="$(tf_artifact_sha stub-chart-0.1.1.tgz)"
publish "${repo}" 0.1.1 helm
assert_rc 0 "PB11: helm publish succeeds"
assert_eq "${chart_sha}" "$(sha256sum "${TF_TMP}/pb11-helm/charts/stub-chart-0.1.1.tgz" | awk '{print $1}')" "PB11: chart uploaded byte-identical"
assert_eq "${chart_sha}" "$(jq -r '.entries["stub-chart"][] | select(.version == "0.1.1") | .digest' "${TF_TMP}/pb11-helm/index.yaml")" "PB11: index entry with digest"
assert_eq "https://charts.example.com/charts/stub-chart-0.1.1.tgz" "$(jq -r '.entries["stub-chart"][0].urls[0]' "${TF_TMP}/pb11-helm/index.yaml")" "PB11: index entry URL"
jq '.entries["stub-chart"] += [{apiVersion: "v2", name: "stub-chart", version: "9.9.9", digest: "feed", urls: ["https://charts.example.com/charts/stub-chart-9.9.9.tgz"]}]' \
  "${TF_TMP}/pb11-helm/index.yaml" > "${TF_TMP}/pb11-index.tmp"
mv "${TF_TMP}/pb11-index.tmp" "${TF_TMP}/pb11-helm/index.yaml"
tf_promoted_release "${repo}" patch
tf_promoted_release "${repo}" patch
for v in 0.1.2 0.1.3; do
  (
    rc=0
    bash "${repo}/scripts/publication/publish.sh" --project-dir "${repo}" --version "${v}" --channel helm \
      > "${TF_TMP}/pb11-${v}.out" 2> "${TF_TMP}/pb11-${v}.err" || rc=$?
    echo "${rc}" > "${TF_TMP}/pb11-${v}.rc"
  ) &
done
wait
assert_eq "0 0" "$(cat "${TF_TMP}/pb11-0.1.2.rc") $(cat "${TF_TMP}/pb11-0.1.3.rc")" "PB11: concurrent helm publishers both succeed"
assert_eq "0.1.1 0.1.2 0.1.3 9.9.9" "$(jq -r '[.entries["stub-chart"][].version] | sort | join(" ")' "${TF_TMP}/pb11-helm/index.yaml")" "PB11: index keeps every entry, including a newer pre-existing one"
repo="$(tf_release_repo pb11b)"
tf_promoted_release "${repo}" patch
mkdir -p "${TF_TMP}/pb11b-helm"
printf 'apiVersion: v1\nentries: {}\n' > "${TF_TMP}/pb11b-helm/index.yaml"
publish "${repo}" 0.1.1 helm
assert_rc 5 "PB11: non-JSON index.yaml exits 5"
assert_eq "apiVersion: v1" "$(head -n 1 "${TF_TMP}/pb11b-helm/index.yaml")" "PB11: non-JSON index untouched"

publish "${TF_TMP}/pb11" 0.1.1 docs
assert_rc 0 "PB11: docs publish succeeds"
assert_eq "<h1>stub 0.1.1</h1>" "$(cat "${TF_TMP}/pb11-docs/0.1.1/index.html")" "PB11: docs version directory written"
assert_eq "present" "$(exists "${TF_TMP}/pb11-docs/0.1.1/api/index.html")" "PB11: nested docs written"
assert_eq "2" "$(jq -r .files "${TF_TMP}/pb11-docs/release-flow/0.1.1.json")" "PB11: docs marker written"
assert_eq "absent" "$(exists "${TF_TMP}/pb11-docs/latest.json")" "PB11: older docs do not take latest (0.1.3 is promoted)"
repo="$(tf_release_repo pb11c)"
STUB_FAULT=docs-evil tf_promoted_release "${repo}" patch
publish "${repo}" 0.1.1 docs
assert_rc 5 "PB11: tarball with ../evil exits 5"
assert_contains "${T_ERR}" "unsafe path" "PB11: names the unsafe path"
assert_eq "" "$(find "${TF_TMP}/pb11c-docs" -type f 2>/dev/null)" "PB11: nothing written for an unsafe tarball"
assert_eq "absent" "$(exists "${TF_TMP}/evil")" "PB11: nothing escaped"
repo="$(tf_release_repo pb11d)"
tf_promoted_release "${repo}" patch
mkdir -p "${TF_TMP}/pb11d-docs/0.1.1"
printf 'someone else\n' > "${TF_TMP}/pb11d-docs/0.1.1/index.html"
publish "${repo}" 0.1.1 docs
assert_rc 5 "PB11: version directory with different content exits 5"
assert_eq "someone else" "$(cat "${TF_TMP}/pb11d-docs/0.1.1/index.html")" "PB11: existing docs untouched"
assert_eq "absent" "$(exists "${TF_TMP}/pb11d-docs/release-flow/0.1.1.json")" "PB11: no marker on conflict"
publish "${repo}" 0.1.1 docs
assert_rc 5 "PB11: rerun still refuses"

t_case "PB12: Helm chart version must equal the release version"
repo="$(tf_release_repo pb12)"
STUB_FAULT=chart-version-mismatch tf_promoted_release "${repo}" patch
publish "${repo}" 0.1.1 helm
assert_rc 5 "PB12: Chart.yaml version 9.9.9 for release 0.1.1 exits 5"
assert_contains "${T_ERR}" "Chart.yaml version 9.9.9 differs from the release version 0.1.1" "PB12: names both versions"
assert_eq "conflict" "$(ledger_field pb12 0.1.1 helm error_class)" "PB12: failed(conflict)"
assert_eq "" "$(find "${TF_TMP}/pb12-helm" -type f 2>/dev/null)" "PB12: nothing written to the chart repository"

t_case "PB13: A later failed attempt never demotes a succeeded channel"
repo="$(tf_release_repo pb13)"
tf_promoted_release "${repo}" patch
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB13: first publish succeeds"
won="$(out_kv attempt_id)"
printf 'tampered\n' > "$(tf_blob_path pb13 "$(tf_artifact_sha stub-0.1.1-any.txt)")"
publish "${repo}" 0.1.1 github-release
assert_rc 6 "PB13: a later attempt fails on integrity"
lost="$(out_kv attempt_id)"
assert_eq "failed integrity" "$(attempt_field pb13 0.1.1 github-release "${lost}" state) $(attempt_field pb13 0.1.1 github-release "${lost}" error_class)" "PB13: the failed attempt is recorded"
assert_eq "2" "$(ledger_attempts pb13 0.1.1 github-release)" "PB13: two attempts in the ledger"
assert_eq "succeeded" "$(ledger_field pb13 0.1.1 github-release state)" "PB13: status stays succeeded"
assert_eq "${won}" "$(ledger_field pb13 0.1.1 github-release attempt_id)" "PB13: status names the succeeded attempt"
lg13() { bash "${ROOT}/scripts/publication/ledger.sh" --uri "file://$(tf_store pb13)" "$@"; }
stale="$(lg13 new-attempt-id)"
lg13 record --binding "$(tf_store pb13)/releases/pb13/0.1.1.json" --channel github-release --attempt "${stale}" --seq 1 --state running >/dev/null
lg13 lock acquire --project pb13 --version 0.1.1 --channel github-release --attempt "${stale}" --ttl 0 >/dev/null
t_run lg13 lock release --project pb13 --version 0.1.1 --channel github-release --attempt "${won}"
assert_rc 3 "PB13: release by another attempt is refused"
assert_eq "present" "$(exists "$(tf_store pb13)/locks/pb13/0.1.1/github-release.json")" "PB13: refused release kept the lock"
t_run lg13 lock break --project pb13 --version 0.1.1 --channel github-release
assert_rc 0 "PB13: expired lock broken"
assert_eq "succeeded" "$(ledger_field pb13 0.1.1 github-release state)" "PB13: a broken lock does not demote the channel"

t_case "PB14: GitHub latest marker reconciled on an already-published release"
repo="$(tf_release_repo pb14)"
tf_promoted_release "${repo}" patch
publish "${repo}" 0.1.1 github-release
rel1="$(release_dir pb14 0.1.1)"
rm -f "${MOCK_GH_ROOT}/latest/acme_pb14"
reset_gh_calls
MOCK_GH_PAGE_SIZE=1 publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB14: republish of a complete release succeeds"
assert_contains "$(gh_writes)" "gh release edit 0.1.1 --repo acme/pb14 --latest=true" "PB14: the missing latest marker is set"
assert_eq "${rel1##*/}" "$(cat "${MOCK_GH_ROOT}/latest/acme_pb14")" "PB14: 0.1.1 is latest"
tf_promoted_release "${repo}" patch
MOCK_GH_PAGE_SIZE=1 publish "${repo}" 0.1.2 github-release
assert_rc 0 "PB14: 0.1.2 publishes with releases on separate pages"
assert_eq "1" "$(find "${MOCK_GH_ROOT}/releases/acme_pb14" -name meta.json -exec jq -r .tag_name {} \; | grep -c '^0\.1\.2$')" "PB14: exactly one 0.1.2 release"
rel2="$(release_dir pb14 0.1.2)"
assert_eq "${rel2##*/}" "$(cat "${MOCK_GH_ROOT}/latest/acme_pb14")" "PB14: 0.1.2 is latest"
basename "${rel1}" > "${MOCK_GH_ROOT}/latest/acme_pb14"
reset_gh_calls
MOCK_GH_PAGE_SIZE=1 publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB14: republish of the older release succeeds"
assert_contains "$(gh_writes)" "gh release edit 0.1.2 --repo acme/pb14 --latest=true" "PB14: latest moves forward to 0.1.2"
assert_not_contains "$(gh_writes)" "edit 0.1.1" "PB14: the older release itself is not modified"
assert_eq "${rel2##*/}" "$(cat "${MOCK_GH_ROOT}/latest/acme_pb14")" "PB14: 0.1.2 is latest again"
reset_gh_calls
publish "${repo}" 0.1.1 github-release
assert_rc 0 "PB14: a reconciled release is complete"
assert_eq "" "$(gh_writes)" "PB14: no further writes"

t_finish
