#!/usr/bin/env bash
# Exercise the real GitHub backend through a local Git database/API fixture.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
mkdir "${TF_TMP}/bin"
ln -s "${ROOT}/tests/pipeline/fixtures/mock-gh-storage" "${TF_TMP}/bin/gh"
export PATH="${TF_TMP}/bin:${PATH}"
export MOCK_GH_STORE="${TF_TMP}/api"
st() { bash "${ROOT}/scripts/storage/storage.sh" --uri github://acme/demo "$@"; }
printf 'original bytes\n' > "${TF_TMP}/blob"
sha="$(sha256sum "${TF_TMP}/blob" | awk '{print $1}')"

t_case 'GH1: Reads never initialize a missing store'
t_run st list ''
assert_rc 0 'empty listing succeeds'
t_run st get-object records/missing "${TF_TMP}/missing"
assert_rc 4 'missing read fails explicitly'
assert_eq '' "$(grep -E '^(POST|PATCH)' "${MOCK_GH_STORE}/calls" || true)" 'reads have no mutations'

t_case 'GH2: Immutable assets, round trip and idempotency'
t_run st put-blob "${TF_TMP}/blob"
assert_rc 0 'put seals and indexes bytes'
assert_eq "${sha}" "${T_OUT}" 'address is byte digest'
t_run st get-blob "${sha}" "${TF_TMP}/download"
assert_rc 0 'get validates asset and bytes'
assert_eq "$(cat "${TF_TMP}/blob")" "$(cat "${TF_TMP}/download")" 'download is identical'
t_run st put-blob "${TF_TMP}/blob"
assert_rc 0 'same put is idempotent'
assert_eq 1 "$(find "${MOCK_GH_STORE}" -name 'release-*.json' | wc -l | tr -d ' ')" 'retry creates no release'

t_case 'GH3: Git CAS preserves conflicts, retries unrelated races and lost responses'
printf 'first\n' > "${TF_TMP}/first"; printf 'second\n' > "${TF_TMP}/second"
t_run st put-cas state/value "${TF_TMP}/first" --expect absent
assert_rc 0 'create CAS succeeds'
token="$(st head state/value)"
t_run st put-cas state/value "${TF_TMP}/second" --expect absent
assert_rc 5 'existing key conflicts'
touch "${MOCK_GH_STORE}/race"
t_run st put-cas state/value "${TF_TMP}/second" --expect "${token}"
assert_rc 0 'sibling ref race retries without losing state'
t_run st put-cas state/value "${TF_TMP}/first" --expect "${token}"
assert_rc 5 'stale per-key token rejected'
token="$(st head state/value)"; touch "${MOCK_GH_STORE}/lost-cas"
t_run st put-cas state/value "${TF_TMP}/first" --expect "${token}"
assert_rc 0 'lost successful CAS response reconciles'

t_case 'GH4: Corruption, mutable releases and truncated metadata fail closed'
printf 'corrupt' > "${MOCK_GH_STORE}/assets/1"
t_run st get-blob "${sha}" "${TF_TMP}/bad"
assert_rc 6 'actual byte substitution rejected'
assert_eq absent "$(test -e "${TF_TMP}/bad" && echo present || echo absent)" 'corrupt download not installed'
cp "${TF_TMP}/blob" "${MOCK_GH_STORE}/assets/1"
jq '.immutable=false' "${MOCK_GH_STORE}/release-1.json" > "${TF_TMP}/r"
cp "${TF_TMP}/r" "${MOCK_GH_STORE}/release-1.json"
t_run st get-blob "${sha}" "${TF_TMP}/mutable"
assert_rc 6 'mutable release rejected even when bytes match'
touch "${MOCK_GH_STORE}/truncated"
t_run st list ''
assert_rc 6 'partial metadata is not a successful listing'
rm "${MOCK_GH_STORE}/truncated"

t_case 'GH5: Missing protections and disabled immutability refuse retention'
touch "${MOCK_GH_STORE}/unprotected"
t_run st put-cas state/new "${TF_TMP}/first" --expect absent
assert_rc 3 'unprotected branch refuses writes'
rm "${MOCK_GH_STORE}/unprotected"
printf 'another blob' > "${TF_TMP}/new"
touch "${MOCK_GH_STORE}/mutable"
t_run st put-blob "${TF_TMP}/new"
assert_rc 6 'disabled immutability refuses indexing'
newsha="$(sha256sum "${TF_TMP}/new" | awk '{print $1}')"
t_run st head "blobs/sha256/${newsha:0:2}/${newsha}"
assert_rc 4 'mutable bytes have no durable pointer'
rm "${MOCK_GH_STORE}/mutable"

t_case 'GH6: Failed uploads resume a draft; lost publish response reconciles'
printf 'resumable blob' > "${TF_TMP}/resume"
touch "${MOCK_GH_STORE}/fail-upload"
t_run st put-blob "${TF_TMP}/resume"
assert_rc 1 'upload failure propagates'
count="$(find "${MOCK_GH_STORE}" -name 'release-*.json' | wc -l)"
rm "${MOCK_GH_STORE}/fail-upload"; touch "${MOCK_GH_STORE}/lost-publish"
printf '2222222222222222222222222222222222222222\n' > "${MOCK_GH_STORE}/head"
t_run st put-blob "${TF_TMP}/resume"
assert_rc 0 'draft resumes and publish response is reconciled'
assert_eq "${count}" "$(find "${MOCK_GH_STORE}" -name 'release-*.json' | wc -l)" 'retry reuses draft'

t_case 'GH7: Unsafe GitHub URI rejected before network'
for uri in 'github://acme/demo/escape' 'github://acme/demo?x' 'github://acme/../demo'; do
  t_run bash "${ROOT}/scripts/storage/storage.sh" --uri "${uri}" list ''
  assert_rc nonzero 'unsafe URI fails'
done

t_case 'GH8: Batch retention is sealed before its candidate record; test-only is refused'
mkdir "${TF_TMP}/candidate"
printf 'candidate artifact' > "${TF_TMP}/candidate/demo-1.0.0.txt"
printf '{"artifacts":[{"name":"demo-1.0.0.txt","target":"any"}],"build_info":{}}' > "${TF_TMP}/inventory"
commit=1111111111111111111111111111111111111111
base=2222222222222222222222222222222222222222
bash "${ROOT}/scripts/candidate-manifest.sh" --dir "${TF_TMP}/candidate" --inventory "${TF_TMP}/inventory" \
  --project demo --repository acme/demo --version 1.0.0 --mode production \
  --base-branch develop --base-commit "${base}" --candidate-branch "release/1.0.0-${base:0:12}" \
  --candidate-commit "${commit}" --run-id 77 --run-attempt 2 --source-date-epoch 1700000000 --adapter tools/adapter.sh >/dev/null
pin="$(sha256sum "${TF_TMP}/candidate/manifest.json" | awk '{print $1}')"
# shellcheck disable=SC2329 # Invoked through t_run.
retain() { st retain-candidate --dir "${TF_TMP}/candidate" --manifest-sha256 "${pin}" --repository acme/demo --run-id 77; }
touch "${MOCK_GH_STORE}/fail-upload"
t_run retain
assert_rc 1 'failed batch upload propagates'
record="candidates/demo/${commit}/77-2.json"
t_run st head "${record}"
assert_rc 4 'incomplete batch has no record'
rm "${MOCK_GH_STORE}/fail-upload"
t_run retain
assert_rc 0 'same verified batch resumes'
assert_eq "record=${record}" "${T_OUT}" 'record is discoverable'
t_run st materialize --record "${record}" --out "${TF_TMP}/materialized"
assert_rc 0 'batch materializes with provenance verification'
assert_eq "${pin}" "$(sha256sum "${TF_TMP}/materialized/manifest.json" | awk '{print $1}')" 'original manifest is preserved'
t_run retain
assert_rc 0 'complete batch is idempotent'
rm "${TF_TMP}/candidate/manifest.json" "${TF_TMP}/candidate/SHA256SUMS"
bash "${ROOT}/scripts/candidate-manifest.sh" --dir "${TF_TMP}/candidate" --inventory "${TF_TMP}/inventory" \
  --project demo --repository acme/demo --version 1.0.0 --mode test-only \
  --base-branch sandbox --base-commit "${base}" --candidate-branch "release/test/1.0.0-${base:0:12}" \
  --candidate-commit "${commit}" --run-id 77 --run-attempt 2 --source-date-epoch 1700000000 --adapter tools/adapter.sh >/dev/null
pin="$(sha256sum "${TF_TMP}/candidate/manifest.json" | awk '{print $1}')"
before="$(grep -Ec '^(POST|PATCH)' "${MOCK_GH_STORE}/calls")"
t_run retain
assert_rc 3 'valid test-only candidate cannot be retained'
assert_eq "${before}" "$(grep -Ec '^(POST|PATCH)' "${MOCK_GH_STORE}/calls")" 'test-only refusal has no writes'

t_case 'GH9: Concurrent creates have a single winner'
set +e
st put-cas locks/race "${TF_TMP}/first" --expect absent > "${TF_TMP}/c1.out" 2> "${TF_TMP}/c1.err" & a=$!
st put-cas locks/race "${TF_TMP}/second" --expect absent > "${TF_TMP}/c2.out" 2> "${TF_TMP}/c2.err" & b=$!
wait "${a}"; ra=$?
wait "${b}"; rb=$?
set -e
assert_eq '0 5' "$(printf '%s\n%s\n' "${ra}" "${rb}" | sort -n | tr '\n' ' ' | sed 's/ $//')" 'one wins, one conflicts'

t_case 'GH10: Lock deletion requires the owner and preserves unrelated keys'
ledger="${ROOT}/scripts/publication/ledger.sh"
t_run bash "${ledger}" --uri github://acme/demo lock acquire --project demo --version 1.0.0 --channel github-release --attempt 20261031T000000Z-aaaaaaaa
assert_rc 0 'publication lock acquired'
t_run bash "${ledger}" --uri github://acme/demo lock release --project demo --version 1.0.0 --channel github-release --attempt 20261031T000000Z-bbbbbbbb
assert_rc 3 'different attempt cannot release lock'
t_run bash "${ledger}" --uri github://acme/demo lock release --project demo --version 1.0.0 --channel github-release --attempt 20261031T000000Z-aaaaaaaa
assert_rc 0 'owner can delete lock with atomic CAS'
t_run st get-object state/value "${TF_TMP}/preserved"
assert_rc 0 'lock deletion preserves other records'
assert_eq first "$(cat "${TF_TMP}/preserved")" 'unrelated record is intact'

t_case 'GH11: GitHub starter assets are repairable only while draft'
printf 'starter upload recovery' > "${TF_TMP}/starter"
touch "${MOCK_GH_STORE}/starter-upload"
t_run st put-blob "${TF_TMP}/starter"
assert_rc 1 'failed upload leaves a starter'
t_run st put-blob "${TF_TMP}/starter"
assert_rc 0 'retry replaces only the incomplete draft starter'
t_run st verify-blob "$(sha256sum "${TF_TMP}/starter" | awk '{print $1}')"
assert_rc 0 'recovered upload verifies'

t_case 'GH12: Pre-existing storage tag cannot spoof the target commit'
printf 'wrong source tag' > "${TF_TMP}/wrong-tag"
touch "${MOCK_GH_STORE}/wrong-tag"
t_run st put-blob "${TF_TMP}/wrong-tag"
assert_rc 6 'incorrect storage tag target refused'
wrongsha="$(sha256sum "${TF_TMP}/wrong-tag" | awk '{print $1}')"
t_run st head "blobs/sha256/${wrongsha:0:2}/${wrongsha}"
assert_rc 4 'wrong target creates no pointer'

t_case 'GH13: Owner configuration requires explicit local opt-in'
before="$(wc -l < "${MOCK_GH_STORE}/calls")"
t_run bash "${ROOT}/scripts/storage/github-bootstrap.sh" acme/demo
assert_rc 0 'default owner setup is a plan'
assert_eq "${before}" "$(wc -l < "${MOCK_GH_STORE}/calls")" 'plan has no API writes or reads'
t_run env GITHUB_ACTIONS=true bash "${ROOT}/scripts/storage/github-bootstrap.sh" acme/demo --apply
assert_rc 3 'workflow token cannot run owner setup'
assert_eq "${before}" "$(wc -l < "${MOCK_GH_STORE}/calls")" 'refusal changes no settings'
t_finish
