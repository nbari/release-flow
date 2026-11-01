# shellcheck shell=bash
# GitHub storage: immutable prerelease assets for bytes, a protected orphan
# branch for records/CAS. Never check out or execute anything on that branch.
# Requires github.com, gh, jq, base64, and Contents read/write as appropriate.
# Sourced by storage.sh; compatible with Bash 3.2.

BE_BRANCH=release-flow-storage
BE_REPO=""
BE_BATCH=false
BE_TAG=""
BE_TARGET=""
BE_RELEASE_ID=""

be_init() {
  BE_REPO="${1#github://}"
  [[ "${BE_REPO}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
    || { echo 'storage: expected github://owner/repo (no path or query)' >&2; return 1; }
  rf_require_tools gh base64 git
  [[ "${GH_HOST:-github.com}" == github.com ]] \
    || { echo 'storage: GitHub storage currently requires github.com' >&2; return 1; }
  mkdir "${WORK}/pending"
}

# API bodies/errors go to private temporary files, never to a command line.
# Only 404 means missing. Permission, transport and malformed responses fail.
be_api() {
  local method="$1" path="$2" out="$3" input="${4:-}" rc=0
  local args=()
  [[ -z "${input}" ]] || args+=(--input "${input}")
  gh api --hostname github.com --method "${method}" \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/${BE_REPO}/${path}" ${args[@]+"${args[@]}"} > "${out}" 2> "${WORK}/api-error" || rc=$?
  if (( rc == 0 )); then return 0; fi
  if jq -e '.status == "404"' "${out}" >/dev/null 2>&1; then return 4; fi
  if jq -e '.status == "409" or .status == "422"' "${out}" >/dev/null 2>&1; then return 5; fi
  echo "storage: GitHub API ${method} ${path} failed; check authentication, permissions and rate limits" >&2
  return 1
}

be_git_blob() {
  local sha="$1" dest="$2"
  [[ "${sha}" =~ ^[0-9a-f]{40}$ ]] || return 6
  be_api GET "git/blobs/${sha}" "${WORK}/git-blob.json" || return $?
  jq -e '.encoding == "base64" and (.size | type == "number" and . <= 1048576)' \
    "${WORK}/git-blob.json" >/dev/null || return 6
  # GNU and BSD base64 both accept -d.
  jq -r .content "${WORK}/git-blob.json" | base64 -d > "${dest}" || return 6
  [[ "$(git hash-object "${dest}")" == "${sha}" ]] || return 6
}

# Populate a consistent snapshot, validating a reserved marker and refusing
# truncated listings. This function has no remote side effects.
be_snapshot() {
  local marker
  be_api GET "git/ref/heads/${BE_BRANCH}" "${WORK}/ref.json" || return $?
  BE_HEAD="$(jq -er --arg ref "refs/heads/${BE_BRANCH}" \
    'select(.ref == $ref and .object.type == "commit") | .object.sha | select(test("^[0-9a-f]{40}$"))' "${WORK}/ref.json")" || return 6
  be_api GET "git/commits/${BE_HEAD}" "${WORK}/commit.json" || return $?
  local tree
  tree="$(jq -er '.tree.sha | select(test("^[0-9a-f]{40}$"))' "${WORK}/commit.json")" || return 6
  be_api GET "git/trees/${tree}?recursive=1" "${WORK}/tree.json" || return $?
  jq -e '.truncated == false and (.tree | type == "array")' "${WORK}/tree.json" >/dev/null || return 6
  marker="$(jq -er '.tree[] | select(.path == ".release-flow-store.json" and .mode == "100644" and .type == "blob") | .sha' "${WORK}/tree.json")" || return 6
  be_git_blob "${marker}" "${WORK}/marker.json" || return $?
  jq -e --arg repo "${BE_REPO}" \
    '. == {schema_version:1,kind:"release-flow-github-store",repository:$repo}' "${WORK}/marker.json" >/dev/null || return 6
}

be_protection() {
  be_api GET "rules/branches/${BE_BRANCH}" "${WORK}/rules.json" || return $?
  jq -e 'type == "array" and any(.[]; .type == "deletion") and any(.[]; .type == "non_fast_forward")' \
    "${WORK}/rules.json" >/dev/null || {
      echo "storage: protect ${BE_BRANCH} against deletion and force pushes first (see docs/GITHUB_STORAGE.md)" >&2
      return 3
    }
}

be_bootstrap_branch() {
  be_protection || return $?
  jq -n --arg repo "${BE_REPO}" \
    '{tree:[{path:".release-flow-store.json",mode:"100644",type:"blob",
      content:({schema_version:1,kind:"release-flow-github-store",repository:$repo}|tojson)}]}' > "${WORK}/request.json"
  be_api POST git/trees "${WORK}/created-tree.json" "${WORK}/request.json" || return $?
  jq -n --arg tree "$(jq -er .sha "${WORK}/created-tree.json")" \
    '{message:"Initialize release storage",tree:$tree,parents:[]}' > "${WORK}/request.json"
  be_api POST git/commits "${WORK}/created-commit.json" "${WORK}/request.json" || return $?
  jq -n --arg ref "refs/heads/${BE_BRANCH}" --arg sha "$(jq -er .sha "${WORK}/created-commit.json")" \
    '{ref:$ref,sha:$sha}' > "${WORK}/request.json"
  local rc=0
  be_api POST git/refs "${WORK}/created-ref.json" "${WORK}/request.json" || rc=$?
  # Another initializer can win; the next snapshot must validate its marker.
  [[ "${rc}" == 0 || "${rc}" == 5 ]]
}

be_token() {
  jq -r --arg key "$1" '[.tree[] | select(.path == $key and .mode == "100644" and .type == "blob") | .sha][0] // "absent"' "${WORK}/tree.json"
}

# Atomic per-key compare-and-swap through a single-parent Git commit and
# force:false ref update. Concurrent sibling commits cannot both fast-forward.
# Retry unrelated changes, but never relax the expected value of this key.
be_metadata_cas() {
  local key="$1" src="$2" expect="$3" rc n=0 tree sha
  [[ "${expect}" == absent || "${expect}" =~ ^[0-9a-f]{40}$ ]] || return 5
  be_protection || return $?
  if [[ "${src}" != DELETE ]]; then
    (( $(rf_file_size "${src}") <= 1048576 )) || { echo 'storage: GitHub metadata is limited to 1 MiB per key' >&2; return 2; }
    base64 < "${src}" > "${WORK}/encoded"
    jq -n --rawfile b "${WORK}/encoded" '{encoding:"base64",content:$b}' > "${WORK}/request.json"
    be_api POST git/blobs "${WORK}/new-blob.json" "${WORK}/request.json" || return $?
    sha="$(jq -er .sha "${WORK}/new-blob.json")"
  else sha="null"; fi
  while (( n < 12 )); do
    n=$(( n + 1 )); rc=0
    be_snapshot || rc=$?
    if (( rc == 4 )); then be_bootstrap_branch || return $?; continue; fi
    (( rc == 0 )) || return "${rc}"
    [[ "$(be_token "${key}")" == "${expect}" ]] || return 5
    tree="$(jq -er .sha "${WORK}/tree.json")"
    jq -n --arg tree "${tree}" --arg key "${key}" --arg sha "${sha}" \
      '{base_tree:$tree,tree:[{path:$key,mode:"100644",type:"blob",sha:(if $sha=="null" then null else $sha end)}]}' > "${WORK}/request.json"
    be_api POST git/trees "${WORK}/new-tree.json" "${WORK}/request.json" || return $?
    jq -n --arg tree "$(jq -er .sha "${WORK}/new-tree.json")" --arg parent "${BE_HEAD}" \
      '{message:"Update release storage",tree:$tree,parents:[$parent]}' > "${WORK}/request.json"
    be_api POST git/commits "${WORK}/new-commit.json" "${WORK}/request.json" || return $?
    sha="$(jq -er .sha "${WORK}/new-commit.json")"
    jq -n --arg sha "${sha}" '{sha:$sha,force:false}' > "${WORK}/request.json"
    rc=0
    be_api PATCH "git/refs/heads/${BE_BRANCH}" "${WORK}/new-ref.json" "${WORK}/request.json" || rc=$?
    (( rc != 0 )) || return 0
    # Reconcile a lost response before retrying. Never overwrite the key if
    # this or another writer already committed it.
    if (( rc != 5 )); then
      be_snapshot || return "${rc}"
      if [[ "${src}" != DELETE ]]; then
        [[ "$(be_token "${key}")" == "$(git hash-object "${src}")" ]] && return 0
      elif [[ "$(be_token "${key}")" == absent ]]; then return 0; fi
      return "${rc}"
    fi
    # Keep the blob SHA across retries (the commit SHA above is different).
    if [[ "${src}" != DELETE ]]; then sha="$(jq -er .sha "${WORK}/new-blob.json")"; else sha=null; fi
  done
  echo 'storage: GitHub metadata is busy; retry the same operation' >&2
  return 5
}

be_head() {
  local token
  be_snapshot || return $?
  token="$(be_token "$1")"
  [[ "${token}" != absent ]] || return 4
  printf '%s\n' "${token}"
}

be_list() {
  local rc=0
  be_snapshot || rc=$?
  (( rc != 4 )) || return 0
  (( rc == 0 )) || return "${rc}"
  jq -r --arg prefix "$1" '.tree[] | select(.type == "blob" and .mode == "100644") | .path
    | select(test("^[A-Za-z0-9][A-Za-z0-9._+-]*(/[A-Za-z0-9][A-Za-z0-9._+-]*)*$") and startswith($prefix))' "${WORK}/tree.json" | LC_ALL=C sort
}

be_validate_pointer() {
  jq -e --arg sha "$2" '
    keys == ["asset_id","kind","release_id","schema_version","sha256","size","tag"] and
    .schema_version == 1 and .kind == "github-release-blob" and .sha256 == $sha and
    (.size | type == "number" and . >= 0 and floor == .) and
    all(.asset_id,.release_id; type == "number" and . > 0 and floor == .) and
    (.tag | type == "string" and test("^release-flow-store-[0-9a-f]{64}$"))' "$1" >/dev/null
}

be_get() {
  local key="$1" dest="$2" token sha rid aid tag
  token="$(be_head "${key}")" || return $?
  case "${key}" in
    blobs/sha256/*)
      sha="${key##*/}"
      [[ "${key}" == "blobs/sha256/${sha:0:2}/${sha}" && "${sha}" =~ ^[0-9a-f]{64}$ ]] || return 6
      be_git_blob "${token}" "${WORK}/pointer.json" || return $?
      be_validate_pointer "${WORK}/pointer.json" "${sha}" || return 6
      rid="$(jq -r .release_id "${WORK}/pointer.json")"
      aid="$(jq -r .asset_id "${WORK}/pointer.json")"
      tag="$(jq -r .tag "${WORK}/pointer.json")"
      be_api GET "releases/${rid}" "${WORK}/release.json" || return $?
      jq -e --arg tag "${tag}" '.immutable == true and .draft == false and .tag_name == $tag' "${WORK}/release.json" >/dev/null || return 6
      be_api GET "releases/assets/${aid}" "${WORK}/asset.json" || return $?
      jq -e --slurpfile p "${WORK}/pointer.json" --arg sha "${sha}" \
        '.id == $p[0].asset_id and .name == $sha and .digest == ("sha256:"+$sha) and .size == $p[0].size and .state == "uploaded"' "${WORK}/asset.json" >/dev/null || return 6
      # Ensure the asset belongs to that release, including paginated inventories.
      gh api --hostname github.com --paginate "repos/${BE_REPO}/releases/${rid}/assets?per_page=100" \
        --jq '.[].id' > "${WORK}/asset-ids" || return 1
      awk -v id="${aid}" '$0 == id { found=1 } END { exit !found }' "${WORK}/asset-ids" || return 6
      gh api --hostname github.com --allow-escape-sequences -H 'Accept: application/octet-stream' \
        "repos/${BE_REPO}/releases/assets/${aid}" > "${dest}" || return 1
      ;;
    *) be_git_blob "${token}" "${dest}" ;;
  esac
}

be_begin_batch() {
  [[ "$(jq -r .repository "$1")" == "${BE_REPO}" ]] || { echo 'storage: GitHub candidate storage must use the candidate repository' >&2; return 3; }
  BE_BATCH=true
  BE_TAG="release-flow-store-$(jq -r .manifest_sha256 "$1")"
  BE_TARGET="$(jq -r .candidate_commit "$1")"
  jq -r '.artifacts[].sha256' "$2/manifest.json" > "${WORK}/expected"
  jq -r '.manifest_sha256,.sha256sums_sha256' "$1" >> "${WORK}/expected"
  (( $(LC_ALL=C sort -u "${WORK}/expected" | wc -l) <= 1000 )) || {
    echo 'storage: GitHub supports at most 1000 unique assets per retained candidate' >&2; return 2;
  }
}

be_release() {
  local rc=0
  be_api GET "releases/tags/${BE_TAG}" "${WORK}/batch-release.json" || rc=$?
  if (( rc == 4 )); then
    # The tag lookup excludes drafts. List every page before creating one.
    gh api --hostname github.com --paginate "repos/${BE_REPO}/releases?per_page=100" \
      --jq '.[]' | jq -s --arg tag "${BE_TAG}" '[.[] | select(.tag_name == $tag)]' > "${WORK}/matches.json" || return 1
    [[ "$(jq length "${WORK}/matches.json")" -le 1 ]] || return 6
    if [[ "$(jq length "${WORK}/matches.json")" == 1 ]]; then
      jq '.[0]' "${WORK}/matches.json" > "${WORK}/batch-release.json"
    else
      jq -n --arg tag "${BE_TAG}" --arg target "${BE_TARGET}" \
        '{tag_name:$tag,target_commitish:$target,name:("Release Flow retained bytes: "+$tag),
          body:"Internal immutable release storage. Public release publishing is independent.",draft:true,prerelease:true,make_latest:"false"}' > "${WORK}/request.json"
      be_api POST releases "${WORK}/batch-release.json" "${WORK}/request.json" || {
        # Reconcile concurrent creation or a lost response; never create another tag.
        be_api GET "releases/tags/${BE_TAG}" "${WORK}/batch-release.json" || return $?
      }
    fi
  elif (( rc != 0 )); then return "${rc}"; fi
  # A retained candidate always has the exact source target. A standalone
  # put-blob is identified only by its digest and can resume after HEAD moves.
  jq -e --arg tag "${BE_TAG}" --arg target "${BE_TARGET}" --arg batch "${BE_BATCH}" \
    '.tag_name == $tag and (.target_commitish == $target or
      ($batch == "false" and (.target_commitish | test("^[0-9a-f]{40}$"))))
      and .prerelease == true and (.id | type == "number" and . > 0)' "${WORK}/batch-release.json" >/dev/null || return 6
  BE_RELEASE_ID="$(jq -r .id "${WORK}/batch-release.json")"
  if [[ "${BE_BATCH}" != true ]]; then BE_TARGET="$(jq -r .target_commitish "${WORK}/batch-release.json")"; fi
}

be_storage_tag() {
  be_api GET "git/ref/tags/${BE_TAG}" "${WORK}/storage-tag.json" || return $?
  jq -e --arg target "${BE_TARGET}" '.object.type == "commit" and .object.sha == $target' \
    "${WORK}/storage-tag.json" >/dev/null || return 6
}

be_asset_pointer() {
  local sha="$1" src="$2" size aid
  size="$(rf_file_size "${src}")"
  (( size < 2147483648 )) || { echo 'storage: GitHub assets must be smaller than 2 GiB' >&2; return 2; }
  be_release || return $?
  gh api --hostname github.com --paginate "repos/${BE_REPO}/releases/${BE_RELEASE_ID}/assets?per_page=100" \
    --jq '.[]' | jq -s . > "${WORK}/assets.json" || return 1
  aid="$(jq -r --arg sha "${sha}" '[.[] | select(.name == $sha) | .id][0] // empty' "${WORK}/assets.json")"
  if [[ -n "${aid}" ]] && jq -e --arg sha "${sha}" \
      'any(.[]; .name == $sha and .state == "starter" and .size == 0 and .digest == null)' "${WORK}/assets.json" >/dev/null; then
    # GitHub can leave a zero-byte starter after an upstream upload failure.
    # It is not retained content. Repair only this incomplete draft asset;
    # never delete a digest mismatch or a sealed asset.
    [[ "$(jq -r .draft "${WORK}/batch-release.json")" == true ]] || return 6
    gh release delete-asset "${BE_TAG}" "${sha}" --repo "github.com/${BE_REPO}" --yes >/dev/null || return 1
    aid=""
  fi
  if [[ -z "${aid}" ]]; then
    [[ "$(jq -r .draft "${WORK}/batch-release.json")" == true ]] || return 6
    # gh release upload does not replace an existing asset (no --clobber).
    cp "${src}" "${WORK}/${sha}"
    gh release upload "${BE_TAG}" "${WORK}/${sha}" --repo "github.com/${BE_REPO}" >/dev/null || {
      echo 'storage: asset upload failed; retry retention with the same verified candidate' >&2; return 1;
    }
    rm "${WORK}/${sha}"
    gh api --hostname github.com --paginate "repos/${BE_REPO}/releases/${BE_RELEASE_ID}/assets?per_page=100" \
      --jq '.[]' | jq -s . > "${WORK}/assets.json" || return 1
  fi
  jq -e --arg sha "${sha}" --argjson size "${size}" \
    '[.[] | select(.name == $sha)] | length == 1 and .[0].state == "uploaded" and .[0].size == $size and .[0].digest == ("sha256:"+$sha)' "${WORK}/assets.json" >/dev/null || return 6
  aid="$(jq -r --arg sha "${sha}" '.[] | select(.name == $sha) | .id' "${WORK}/assets.json")"
  jq -n --arg sha "${sha}" --arg tag "${BE_TAG}" --argjson size "${size}" \
    --argjson release_id "${BE_RELEASE_ID}" --argjson asset_id "${aid}" \
    '{schema_version:1,kind:"github-release-blob",sha256:$sha,size:$size,tag:$tag,release_id:$release_id,asset_id:$asset_id}' \
    > "${WORK}/pending/${sha}"
}

be_commit_batch() {
  local file sha rc
  [[ -n "${BE_RELEASE_ID}" ]] || return 0
  gh api --hostname github.com --paginate "repos/${BE_REPO}/releases/${BE_RELEASE_ID}/assets?per_page=100" \
    --jq '.[]' | jq -s . > "${WORK}/sealing-assets.json" || return 1
  jq -e --rawfile expected "${WORK}/expected" \
    'all(.[]; .name as $n | ($expected | split("\n") | index($n)) != null)' "${WORK}/sealing-assets.json" >/dev/null || return 6
  rc=0
  be_storage_tag || rc=$?
  # A draft need not have a tag yet; an existing tag must already match.
  if (( rc != 0 )); then
    [[ "${rc}" == 4 && "$(jq -r .draft "${WORK}/batch-release.json")" == true ]] || return "${rc}"
  fi
  # All uploads finish before sealing the release. Fail closed if immutability
  # was not enabled by the owner; a published mutable release is never indexed.
  printf '%s\n' '{"draft":false,"make_latest":"false"}' > "${WORK}/request.json"
  if [[ "$(jq -r .draft "${WORK}/batch-release.json")" == true ]]; then
    be_api PATCH "releases/${BE_RELEASE_ID}" "${WORK}/sealed.json" "${WORK}/request.json" || true
  fi
  be_api GET "releases/${BE_RELEASE_ID}" "${WORK}/sealed.json" || return $?
  jq -e '.immutable == true and .draft == false' "${WORK}/sealed.json" >/dev/null || {
    echo 'storage: retained release is mutable; enable immutable releases before preparing a fresh candidate; no candidate record was written' >&2; return 6;
  }
  be_storage_tag || return $?
  for file in "${WORK}/pending/"*; do
    [[ -f "${file}" ]] || continue
    sha="${file##*/}"; rc=0
    be_metadata_cas "blobs/sha256/${sha:0:2}/${sha}" "${file}" absent || rc=$?
    if (( rc == 5 )); then
      be_get "blobs/sha256/${sha:0:2}/${sha}" "${WORK}/dedup" || return $?
      [[ "$(rf_sha256_file "${WORK}/dedup")" == "${sha}" ]] || return 6
    elif (( rc != 0 )); then return "${rc}"; fi
  done
}

be_put_create() {
  local key="$1" src="$2" rc=0 sha
  case "${key}" in
    blobs/sha256/*)
      be_head "${key}" >/dev/null || rc=$?
      (( rc != 0 )) || return 5
      (( rc == 4 )) || return "${rc}"
      sha="${key##*/}"
      [[ "${sha}" =~ ^[0-9a-f]{64}$ && "${key}" == "blobs/sha256/${sha:0:2}/${sha}" && "$(rf_sha256_file "${src}")" == "${sha}" ]] || return 6
      if [[ "${BE_BATCH}" != true ]]; then
        BE_TAG="release-flow-store-${sha}"
        printf '%s\n' "${sha}" > "${WORK}/expected"
        # Standalone blobs have no candidate identity; pin the current default
        # branch commit instead of letting GitHub resolve a mutable target later.
        be_api GET commits/HEAD "${WORK}/target.json" || return $?
        BE_TARGET="$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' "${WORK}/target.json")" || return 6
      fi
      be_protection || return $?
      be_asset_pointer "${sha}" "${src}" || return $?
      if [[ "${BE_BATCH}" != true ]]; then be_commit_batch; fi
      ;;
    *) be_metadata_cas "${key}" "${src}" absent ;;
  esac
}

be_put_cas() { be_metadata_cas "$1" "$2" "$3"; }
be_delete_if() { be_metadata_cas "$1" DELETE "$2"; }
