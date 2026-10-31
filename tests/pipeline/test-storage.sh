#!/usr/bin/env bash
# Durable storage and publication ledger: content addressing, create-only
# records, corruption and absence detection, concurrent writers, candidate
# retention, ledger derivation and locks, and the S3 backend contract.
set -euo pipefail
# shellcheck source=tests/pipeline/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=scripts/lib/common.sh
source "${ROOT}/scripts/lib/common.sh"

storage="${ROOT}/scripts/storage/storage.sh"
ledger="${ROOT}/scripts/publication/ledger.sh"
STORE="file://${TF_TMP}/store"
COMMIT="1111111111111111111111111111111111111111"
BASE="2222222222222222222222222222222222222222"

st() {
  bash "${storage}" --uri "${STORE}" "$@"
}

blob_path() {
  printf '%s/store/blobs/sha256/%s/%s' "${TF_TMP}" "${1:0:2}" "$1"
}

exists() {
  if [[ -e "$1" ]]; then echo present; else echo absent; fi
}

# make_candidate <dir> <mode>: a verified candidate directory (run 77, attempt 2)
make_candidate() {
  local dir="$1" mode="$2" branch inv
  mkdir -p "${dir}"
  printf 'artifact one\n' > "${dir}/app-1.0.0-linux.tar.gz"
  printf 'artifact two\n' > "${dir}/app-1.0.0-any.txt"
  inv="${TF_TMP}/inv-$(basename "${dir}").json"
  printf '{"artifacts":[{"name":"app-1.0.0-linux.tar.gz","target":"linux"},{"name":"app-1.0.0-any.txt","target":"any"}],"build_info":{}}\n' > "${inv}"
  if [[ "${mode}" == "production" ]]; then branch="release/1.0.0-${BASE:0:12}"; else branch="release/test/1.0.0-${BASE:0:12}"; fi
  bash "${ROOT}/scripts/candidate-manifest.sh" --dir "${dir}" --inventory "${inv}" \
    --project demo --repository acme/demo --version 1.0.0 --mode "${mode}" \
    --base-branch develop --base-commit "${BASE}" --candidate-branch "${branch}" \
    --candidate-commit "${COMMIT}" --run-id 77 --run-attempt 2 --source-date-epoch 1700000000 \
    --adapter tools/adapter.sh
}

t_case "ST01: Content-addressed round trip (fs)"
printf 'hello blob\n' > "${TF_TMP}/b1"
want="$(sha256sum "${TF_TMP}/b1" | awk '{print $1}')"
t_run st put-blob "${TF_TMP}/b1"
assert_rc 0 "ST01: put-blob succeeds"
assert_eq "${want}" "${T_OUT}" "ST01: put-blob prints the sha256"
stat_before="$(stat -c '%i %Y' "$(blob_path "${want}")")"
sleep 1
t_run st put-blob "${TF_TMP}/b1"
assert_rc 0 "ST01: identical re-put exits 0"
assert_eq "${stat_before}" "$(stat -c '%i %Y' "$(blob_path "${want}")")" "ST01: identical re-put leaves inode and mtime"
t_run st get-blob "${want}" "${TF_TMP}/b1.out"
assert_rc 0 "ST01: get-blob succeeds"
assert_eq "$(cat "${TF_TMP}/b1")" "$(cat "${TF_TMP}/b1.out")" "ST01: get-blob returns identical bytes"
t_run st get-blob "${want}" "${TF_TMP}/b1.size" --size 11
assert_rc 0 "ST01: get-blob accepts the right size"
t_run st get-blob "${want}" "${TF_TMP}/b1.badsize" --size 12
assert_rc 6 "ST01: get-blob rejects a wrong size"
assert_eq "absent" "$(exists "${TF_TMP}/b1.badsize")" "ST01: wrong size leaves no destination"
t_run st get-blob nothex "${TF_TMP}/x"
assert_rc 2 "ST01: invalid digest is a usage error"

t_case "ST02: Corruption detected"
printf 'to be corrupted\n' > "${TF_TMP}/b2"
sha2="$(st put-blob "${TF_TMP}/b2")"
printf 'flipped\n' > "$(blob_path "${sha2}")"
t_run st get-blob "${sha2}" "${TF_TMP}/b2.out"
assert_rc 6 "ST02: get-blob exits 6 on corrupt content"
assert_contains "${T_ERR}" "integrity failure" "ST02: reports the integrity failure"
assert_eq "absent" "$(exists "${TF_TMP}/b2.out")" "ST02: no destination file"
assert_eq "" "$(find "${TF_TMP}" -maxdepth 1 -name 'b2.out.tmp*')" "ST02: no temp file left"
t_run st verify-blob "${sha2}"
assert_rc 6 "ST02: verify-blob exits 6"
t_run st put-blob "${TF_TMP}/b2"
assert_rc 6 "ST02: re-put over a corrupt blob reports a corrupt store"

t_case "ST03: Missing object"
missing_sha="$(printf 'never stored' | sha256sum | awk '{print $1}')"
t_run st get-blob "${missing_sha}" "${TF_TMP}/b3.out"
assert_rc 4 "ST03: get-blob exits 4"
assert_contains "${T_ERR}" "missing" "ST03: get-blob says missing"
assert_eq "absent" "$(exists "${TF_TMP}/b3.out")" "ST03: no destination file"
t_run st verify-blob "${missing_sha}"
assert_rc 4 "ST03: verify-blob exits 4"
assert_contains "${T_ERR}" "missing" "ST03: verify-blob says missing"
t_run st get-record candidates/demo/x.json "${TF_TMP}/r3" --kind candidate-record
assert_rc 4 "ST03: get-record exits 4"
assert_contains "${T_ERR}" "missing" "ST03: get-record says missing"

t_case "ST04: Create-only records"
rec="${TF_TMP}/rec4.json"
jq -n --arg c "${COMMIT}" --arg b "${BASE}" --arg m "${want}" '{schema_version: 1, kind: "candidate-record",
  project: "demo", repository: "acme/demo", version: "1.0.0", mode: "production", candidate_commit: $c,
  base_commit: $b, candidate_branch: ("release/1.0.0-" + $b[0:12]), run_id: "5", run_attempt: 1,
  manifest_sha256: $m, sha256sums_sha256: $m}' > "${rec}"
key4="candidates/demo/${COMMIT}/5-1.json"
t_run st put-record "${key4}" "${rec}" --kind candidate-record
assert_rc 0 "ST04: first put-record succeeds"
original="$(cat "${TF_TMP}/store/${key4}")"
t_run st put-record "${key4}" "${rec}" --kind candidate-record
assert_rc 0 "ST04: identical put-record exits 0"
jq '.run_id = "5" | .sha256sums_sha256 = "'"${missing_sha}"'"' "${rec}" > "${TF_TMP}/rec4b.json"
t_run st put-record "${key4}" "${TF_TMP}/rec4b.json" --kind candidate-record
assert_rc 5 "ST04: different content under the same key exits 5"
assert_eq "${original}" "$(cat "${TF_TMP}/store/${key4}")" "ST04: original bytes kept"
n=0
for filter in '.extra = 1' '.manifest_sha256 = "abc"' '.kind = "release-binding"'; do
  n=$(( n + 1 ))
  jq "${filter}" "${rec}" > "${TF_TMP}/rec4-bad${n}.json"
  t_run st put-record "candidates/demo/bad-${n}.json" "${TF_TMP}/rec4-bad${n}.json" --kind candidate-record
  assert_rc 1 "ST04: schema-invalid record '${filter}' exits 1"
  assert_eq "absent" "$(exists "${TF_TMP}/store/candidates/demo/bad-${n}.json")" "ST04: '${filter}' wrote nothing"
done
printf '{"schema_version":1}{"schema_version":1}' > "${TF_TMP}/rec4-multi.json"
t_run st put-record candidates/demo/multi.json "${TF_TMP}/rec4-multi.json" --kind candidate-record
assert_rc 1 "ST04: concatenated JSON documents are rejected"
t_run st put-object '../escape' "${rec}"
assert_rc 2 "ST04: path traversal key is a usage error"
t_run st delete-lock "${key4}" --attempt anyone
assert_rc 2 "ST04: delete outside locks/ is refused"
assert_eq "present" "$(exists "${TF_TMP}/store/${key4}")" "ST04: refused delete kept the record"

t_case "ST05: Concurrent create race"
race_ok=0
for round in $(seq 1 20); do
  printf 'writer A %s\n' "${round}" > "${TF_TMP}/race-a"
  printf 'writer B %s\n' "${round}" > "${TF_TMP}/race-b"
  key="race/${round}.txt"
  ( rc=0; st put-object "${key}" "${TF_TMP}/race-a" 2>/dev/null || rc=$?; echo "${rc}" > "${TF_TMP}/race-a.rc" ) &
  pa=$!
  ( rc=0; st put-object "${key}" "${TF_TMP}/race-b" 2>/dev/null || rc=$?; echo "${rc}" > "${TF_TMP}/race-b.rc" ) &
  pb=$!
  wait "${pa}" "${pb}" || true
  ra="$(cat "${TF_TMP}/race-a.rc")"
  rb="$(cat "${TF_TMP}/race-b.rc")"
  stored="$(cat "${TF_TMP}/store/${key}")"
  if [[ "${ra}" == 0 && "${rb}" == 5 && "${stored}" == "writer A ${round}" ]] || \
     [[ "${ra}" == 5 && "${rb}" == 0 && "${stored}" == "writer B ${round}" ]]; then
    race_ok=$(( race_ok + 1 ))
  else
    printf '    round %s: a=%s b=%s stored=%s\n' "${round}" "${ra}" "${rb}" "${stored}" >&2
  fi
done
assert_eq "20" "${race_ok}" "ST05: every round has exactly one winner whose bytes are stored"
assert_eq "" "$(find "${TF_TMP}/store/race" -name '.*')" "ST05: no temp files left"

t_case "ST06: retain-candidate"
c6="${TF_TMP}/c6"
m6="$(make_candidate "${c6}" production)"
t_run st retain-candidate --dir "${c6}" --manifest-sha256 "${m6}" --repository acme/demo --run-id 77
assert_rc 0 "ST06: retain-candidate succeeds"
assert_eq "record=candidates/demo/${COMMIT}/77-2.json" "${T_OUT}" "ST06: prints the record key"
missing_blobs=0
for f in app-1.0.0-linux.tar.gz app-1.0.0-any.txt manifest.json SHA256SUMS; do
  [[ -f "$(blob_path "$(sha256sum "${c6}/${f}" | awk '{print $1}')")" ]] || missing_blobs=$(( missing_blobs + 1 ))
done
assert_eq "0" "${missing_blobs}" "ST06: every artifact, manifest and SHA256SUMS stored as blobs"
rec6="${TF_TMP}/store/candidates/demo/${COMMIT}/77-2.json"
assert_eq "${m6}" "$(jq -r .manifest_sha256 "${rec6}")" "ST06: record pins the manifest digest"
assert_eq "2" "$(jq -r .run_attempt "${rec6}")" "ST06: record carries the run attempt"
assert_eq "$(sha256sum "${c6}/SHA256SUMS" | awk '{print $1}')" "$(jq -r .sha256sums_sha256 "${rec6}")" "ST06: record pins SHA256SUMS"
t_run st retain-candidate --dir "${c6}" --manifest-sha256 "${m6}" --repository acme/demo --run-id 77
assert_rc 0 "ST06: retaining again is idempotent"
out6="${TF_TMP}/c6-out"
t_run st materialize --record "candidates/demo/${COMMIT}/77-2.json" --out "${out6}"
assert_rc 0 "ST06: materialize rebuilds a verified candidate directory"
assert_eq "$(cat "${c6}/app-1.0.0-linux.tar.gz")" "$(cat "${out6}/app-1.0.0-linux.tar.gz")" "ST06: materialized bytes equal the originals"

store_before="$(find "${TF_TMP}/store" -type f | sort)"
c6t="${TF_TMP}/c6-tampered"
m6t="$(make_candidate "${c6t}" production)"
printf 'tampered\n' >> "${c6t}/app-1.0.0-linux.tar.gz"
rm -rf "${TF_TMP}/store/candidates/demo/${COMMIT}"
store_before="$(find "${TF_TMP}/store" -type f | sort)"
t_run st retain-candidate --dir "${c6t}" --manifest-sha256 "${m6t}" --repository acme/demo --run-id 77
assert_rc 6 "ST06: tampered artifact is refused"
assert_eq "${store_before}" "$(find "${TF_TMP}/store" -type f | sort)" "ST06: tampered candidate stored no blobs and no record"
c6x="${TF_TMP}/c6-test"
m6x="$(make_candidate "${c6x}" test-only)"
t_run st retain-candidate --dir "${c6x}" --manifest-sha256 "${m6x}" --repository acme/demo --run-id 77
assert_rc 3 "ST06: test-only candidate exits 3"
assert_contains "${T_ERR}" "never retained" "ST06: explains test-only refusal"
t_run st retain-candidate --dir "${c6}" --manifest-sha256 "${missing_sha}" --repository acme/demo --run-id 77
assert_rc 6 "ST06: wrong --manifest-sha256 is refused"
t_run st retain-candidate --dir "${c6}" --manifest-sha256 "${m6}" --repository acme/other --run-id 77
assert_rc 6 "ST06: wrong repository is refused"
assert_eq "${store_before}" "$(find "${TF_TMP}/store" -type f | sort)" "ST06: refused retains wrote nothing"

t_case "ST07: Ledger states and derivation"
binding="${TF_TMP}/binding.json"
jq -n --arg c "${COMMIT}" --arg b "${BASE}" --arg m "${m6}" --arg uri "${STORE}" '{schema_version: 1,
  kind: "release-binding", project: "demo", repository: "acme/demo", version: "1.0.0", candidate_commit: $c,
  base_commit: $b, candidate_branch: ("release/1.0.0-" + $b[0:12]), run_id: "77", run_attempt: 2,
  manifest_sha256: $m, sha256sums_sha256: $m, storage: $uri, tag: "1.0.0", tag_object: $c, storage_uri: $uri}' > "${binding}"
st put-record releases/demo/1.0.0.json "${binding}" --kind release-binding
lg() { bash "${ledger}" --uri "${STORE}" "$@"; }
a1="$(lg new-attempt-id)"
assert_contains "$(printf '%s' "${a1}" | grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$' || true)" "${a1}" "ST07: attempt id format"
t_run lg record --binding "${binding}" --channel github-release --attempt "${a1}" --seq 1 --state running
assert_rc 0 "ST07: running recorded"
t_run lg record --binding "${binding}" --channel github-release --attempt "${a1}" --seq 2 --state failed --error-class transient --error "upload failed"
assert_rc 0 "ST07: failed recorded"
sleep 1
a2="$(lg new-attempt-id)"
lg record --binding "${binding}" --channel github-release --attempt "${a2}" --seq 1 --state running >/dev/null
printf '{"release_id": 1}' > "${TF_TMP}/obs.json"
t_run lg record --binding "${binding}" --channel github-release --attempt "${a2}" --seq 2 --state succeeded --observed-file "${TF_TMP}/obs.json"
assert_rc 0 "ST07: succeeded recorded"
t_run lg status --project demo --version 1.0.0
assert_rc 0 "ST07: status succeeds"
assert_eq "succeeded" "$(printf '%s' "${T_OUT}" | jq -r '.channels["github-release"].state')" "ST07: latest state is succeeded"
assert_eq "${a2}" "$(printf '%s' "${T_OUT}" | jq -r '.channels["github-release"].attempt_id')" "ST07: latest attempt wins"
t_run lg record --binding "${binding}" --channel github-release --attempt "${a2}" --seq 2 --state failed --error-class transient --error x
assert_rc 5 "ST07: reusing a seq exits 5"
t_run lg record --binding "${binding}" --channel github-release --attempt "${a2}" --seq 3 --state bogus
assert_rc 1 "ST07: invalid state exits 1"
t_run lg record --binding "${binding}" --channel github-release --attempt "${a2}" --seq 3 --state succeeded --error-class transient --error x
assert_rc 1 "ST07: error class on a success is a schema violation"
assert_eq "" "$(st list "ledger/demo/1.0.0/github-release/${a2}/0003")" "ST07: rejected events wrote nothing"
a4="$(lg new-attempt-id)"
lg record --binding "${binding}" --channel github-release --attempt "${a4}" --seq 1 --state failed --error-class transient --error "late retry failed" >/dev/null
t_run lg status --project demo --version 1.0.0 --channel github-release
assert_eq "succeeded ${a2}" "$(printf '%s' "${T_OUT}" | jq -r '.channels["github-release"] | "\(.state) \(.attempt_id)"')" "ST07: a later failed attempt does not demote succeeded"
a3="$(lg new-attempt-id)"
lg record --binding "${binding}" --channel docs --attempt "${a3}" --seq 1 --state failed --error-class conflict --error "differs" >/dev/null
status7="$(lg status --project demo --version 1.0.0)"
assert_eq "PUBLISHED" "$(rf_publication_state "${status7}" '{"github-release":{"required":true},"docs":{"required":false}}')" "ST07: optional failure keeps PUBLISHED"
assert_eq "PROMOTED" "$(rf_publication_state "${status7}" '{"github-release":{"required":true},"docs":{"required":true}}')" "ST07: required failure is PROMOTED"
assert_eq "PROMOTED" "$(rf_publication_state "${status7}" '{"github-release":{"required":true},"oci":{"required":true}}')" "ST07: pending required channel is PROMOTED"
t_run lg status --project demo --version 1.0.0 --channel oci
assert_eq "pending" "$(printf '%s' "${T_OUT}" | jq -r '.channels.oci.state')" "ST07: channel without events is pending"

t_case "ST08: Ledger lock"
l1="$(lg new-attempt-id)"
l2="$(lg new-attempt-id)"
t_run lg lock acquire --project demo --version 1.0.0 --channel oci --attempt "${l1}"
assert_rc 0 "ST08: acquire succeeds"
t_run lg lock acquire --project demo --version 1.0.0 --channel oci --attempt "${l2}"
assert_rc 9 "ST08: second acquire is busy"
t_run lg lock release --project demo --version 1.0.0 --channel oci --attempt "${l2}"
assert_rc 3 "ST08: release by the wrong attempt is refused"
assert_eq "present" "$(exists "${TF_TMP}/store/locks/demo/1.0.0/oci.json")" "ST08: refused release kept the lock"
t_run lg lock break --project demo --version 1.0.0 --channel oci
assert_rc 9 "ST08: break of a live lock exits 9"
t_run lg lock release --project demo --version 1.0.0 --channel oci --attempt "${l1}"
assert_rc 0 "ST08: owner release succeeds"
assert_eq "absent" "$(exists "${TF_TMP}/store/locks/demo/1.0.0/oci.json")" "ST08: lock removed"
lg record --binding "${binding}" --channel oci --attempt "${l2}" --seq 1 --state running >/dev/null
lg lock acquire --project demo --version 1.0.0 --channel oci --attempt "${l2}" --ttl 0 >/dev/null
t_run lg lock break --project demo --version 1.0.0 --channel oci
assert_rc 0 "ST08: break of an expired lock succeeds"
assert_eq "absent" "$(exists "${TF_TMP}/store/locks/demo/1.0.0/oci.json")" "ST08: expired lock removed"
s8="$(lg status --project demo --version 1.0.0 --channel oci)"
assert_eq "failed" "$(printf '%s' "${s8}" | jq -r .channels.oci.state)" "ST08: break records a failed event"
assert_eq "lock broken" "$(printf '%s' "${s8}" | jq -r .channels.oci.error)" "ST08: break event says lock broken"
assert_eq "2" "$(printf '%s' "${s8}" | jq -r .channels.oci.seq)" "ST08: break event continues the attempt's seq"

t_case "ST09: S3 backend contract (mock-aws)"
mockbin="${TF_TMP}/mock-aws-bin"
mkdir -p "${mockbin}"
ln -s "${ROOT}/tests/pipeline/fixtures/mock-aws.sh" "${mockbin}/aws"
export MOCK_S3_ROOT="${TF_TMP}/s3"
s3() { PATH="${mockbin}:${PATH}" bash "${storage}" --uri "s3://bucket-one/pre" "$@"; }
printf 's3 blob\n' > "${TF_TMP}/s3b"
t_run s3 put-object obj/a.txt "${TF_TMP}/s3b"
assert_rc 0 "ST09: create-only put succeeds"
put_line="$(grep 'put-object' "${MOCK_S3_ROOT}/calls.log" | grep -v help | tail -n 1)"
assert_contains "${put_line}" "--if-none-match *" "ST09: put-create sends If-None-Match *"
assert_contains "${put_line}" "--checksum-sha256" "ST09: put-create sends a sha256 checksum"
assert_contains "${put_line}" "--key pre/obj/a.txt" "ST09: keys are under the prefix"
printf 'other bytes\n' > "${TF_TMP}/s3c"
t_run s3 put-object obj/a.txt "${TF_TMP}/s3c"
assert_rc 5 "ST09: existing object maps to conflict"
t_run s3 put-object obj/a.txt "${TF_TMP}/s3b"
assert_rc 0 "ST09: identical existing object is idempotent"
token="$(s3 head obj/a.txt)"
assert_eq "$(sha256sum "${TF_TMP}/s3b" | awk '{print $1}')" "${token}" "ST09: head returns the ETag"
t_run s3 put-cas obj/a.txt "${TF_TMP}/s3c" --expect "${missing_sha}"
assert_rc 5 "ST09: stale CAS token maps to conflict"
t_run s3 put-cas obj/a.txt "${TF_TMP}/s3c" --expect "${token}"
assert_rc 0 "ST09: CAS with the current token succeeds"
assert_contains "$(grep 'put-object' "${MOCK_S3_ROOT}/calls.log" | tail -n 1)" "--if-match" "ST09: CAS sends If-Match"
t_run s3 put-cas obj/new.txt "${TF_TMP}/s3c" --expect absent
assert_rc 0 "ST09: CAS create from absent succeeds"
t_run s3 put-cas obj/new.txt "${TF_TMP}/s3c" --expect absent
assert_rc 5 "ST09: CAS create over an existing object conflicts"
t_run s3 get-object obj/none.txt "${TF_TMP}/s3none"
assert_rc 4 "ST09: NoSuchKey maps to missing"
t_run s3 head obj/none.txt
assert_rc 4 "ST09: 404 head maps to missing"
t_run s3 list obj/
assert_eq "$(printf 'obj/a.txt\nobj/new.txt')" "${T_OUT}" "ST09: list strips the prefix and sorts"
sha9="$(s3 put-blob "${TF_TMP}/s3b")"
t_run s3 verify-blob "${sha9}"
assert_rc 0 "ST09: blob round trip over S3"
MOCK_AWS_NO_CONDITIONAL=1 t_run s3 list obj/
assert_rc 1 "ST09: CLI without conditional writes is refused"
assert_contains "${T_ERR}" "conditional writes unsupported" "ST09: explains missing conditional writes"

t_case "ST10: Lock ownership, stale CAS locks, unsafe prefixes and names"
lock10="locks/demo/1.0.0/docs.json"
o10="$(lg new-attempt-id)"
lg lock acquire --project demo --version 1.0.0 --channel docs --attempt "${o10}" >/dev/null
t_run st delete-lock "${lock10}"
assert_rc 2 "ST10: delete-lock requires the owning attempt"
t_run st delete-lock "${lock10}" --attempt "$(lg new-attempt-id)"
assert_rc 5 "ST10: delete-lock by another attempt is a conflict"
assert_eq "present" "$(exists "${TF_TMP}/store/${lock10}")" "ST10: another attempt's delete kept the lock"
t_run st delete-lock "${lock10}" --attempt "${o10}"
assert_rc 0 "ST10: the owner deletes its lock"
assert_eq "absent" "$(exists "${TF_TMP}/store/${lock10}")" "ST10: lock removed"
t_run st delete-lock "${lock10}" --attempt "${o10}"
assert_rc 4 "ST10: deleting an absent lock is missing"
jq -n --arg a "${o10}" '{schema_version: 1, kind: "publication-lock", project: "demo", version: "1.0.0", channel: "docs",
  attempt_id: $a, acquired_at: 1700000000, expires_at: 1700003600}' > "${TF_TMP}/lock10.json"
s3 put-record "${lock10}" "${TF_TMP}/lock10.json" --kind publication-lock
t_run s3 delete-lock "${lock10}" --attempt "${o10}"
assert_rc 0 "ST10: S3 owner delete succeeds"
assert_contains "$(grep 'delete-object' "${MOCK_S3_ROOT}/calls.log" | tail -n 1)" "--if-match" "ST10: S3 lock delete is conditional (If-Match)"
assert_eq "absent" "$(exists "${MOCK_S3_ROOT}/bucket-one/pre/${lock10}")" "ST10: S3 lock removed"

printf 'pointer one\n' > "${TF_TMP}/p1"
printf 'pointer two\n' > "${TF_TMP}/p2"
printf 'pointer three\n' > "${TF_TMP}/p3"
st put-cas pointers/demo/x.json "${TF_TMP}/p1" --expect absent
bash -c 'exit 0' &
dead_pid=$!
wait "${dead_pid}" || true
mkdir "${TF_TMP}/store/pointers/demo/.x.json.cas.lock"
printf '%s\n' "${dead_pid}" > "${TF_TMP}/store/pointers/demo/.x.json.cas.lock/pid"
t_run st put-cas pointers/demo/x.json "${TF_TMP}/p2" --expect "$(st head pointers/demo/x.json)"
assert_rc 0 "ST10: a lock left by a dead writer is reclaimed"
assert_contains "${T_ERR}" "reclaimed stale CAS lock for pointers/demo/x.json (owner pid ${dead_pid})" "ST10: reclaim is reported"
assert_eq "pointer two" "$(cat "${TF_TMP}/store/pointers/demo/x.json")" "ST10: CAS applied after reclaim"
mkdir "${TF_TMP}/store/pointers/demo/.x.json.cas.lock"
touch -d '@1700000000' "${TF_TMP}/store/pointers/demo/.x.json.cas.lock"
t_run st put-cas pointers/demo/x.json "${TF_TMP}/p3" --expect "$(st head pointers/demo/x.json)"
assert_rc 0 "ST10: a lock older than 10 s without an owner is reclaimed"
assert_eq "pointer three" "$(cat "${TF_TMP}/store/pointers/demo/x.json")" "ST10: CAS applied after age reclaim"
assert_eq "" "$(find "${TF_TMP}/store/pointers/demo" -name '.*' 2>/dev/null)" "ST10: no lock or guard left behind"

for p in ../ ledger/../ ./ /ledger/ 'ledger//'; do
  t_run st list "${p}"
  assert_rc 2 "ST10: list prefix '${p}' is a usage error"
done
t_run st list ""
assert_rc 0 "ST10: empty list prefix is allowed"
t_run st list ledger/demo/1.0.0/
assert_rc 0 "ST10: list of a key prefix succeeds"

jq -n '{schema_version: 1, artifacts: [{name: "../evil", target: "any", size: 5, sha256: "'"${missing_sha}"'"}]}' > "${TF_TMP}/evil-manifest.json"
evil_m="$(st put-blob "${TF_TMP}/evil-manifest.json")"
jq --arg m "${evil_m}" '.manifest_sha256 = $m | .run_id = "66"' "${rec}" > "${TF_TMP}/rec10.json"
st put-record "candidates/demo/${COMMIT}/66-1.json" "${TF_TMP}/rec10.json" --kind candidate-record
t_run st materialize --record "candidates/demo/${COMMIT}/66-1.json" --out "${TF_TMP}/m10/out"
assert_rc 6 "ST10: unsafe artifact names exit 6"
assert_contains "${T_ERR}" "unsafe or duplicate artifact names" "ST10: names the problem"
assert_eq "" "$(find "${TF_TMP}/m10" -type f 2>/dev/null)" "ST10: nothing written for an unsafe manifest"
assert_eq "absent" "$(exists "${TF_TMP}/m10/evil")" "ST10: nothing escaped"

t_finish
