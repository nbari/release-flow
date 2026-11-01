# shellcheck shell=bash
# The signed release tag is the authoritative binding of a version to its
# candidate commit, CI evidence and manifest digest. Sourced, never executed.
# Requires lib/common.sh, lib/schema.sh and lib/github.sh. bash 3.2 compatible.
#
# Tag message format (strict Git trailers; every key exactly once):
#
#   release-flow <project> <version>
#
#   Promoted by release-flow.
#
#   Release-Project: <project>
#   Release-Repository: <owner/name>
#   Release-Version: <X.Y.Z>
#   Release-Commit: <C>
#   Release-Base-Commit: <B>
#   Release-Candidate-Branch: release/<X.Y.Z>-<b12>
#   Release-Candidate-Run: <run_id>
#   Release-Candidate-Run-Attempt: <A>
#   Release-Manifest-SHA256: <M>
#   Release-SHA256SUMS-SHA256: <S>
#   Release-Storage: <storage uri at promotion>

if [[ -n "${RF_TAG_LOADED:-}" ]]; then
  return 0
fi
RF_TAG_LOADED=1

# Trailer key <TAB> promotion-record field
RF_TAG_TRAILERS='Release-Project	project
Release-Repository	repository
Release-Version	version
Release-Commit	candidate_commit
Release-Base-Commit	base_commit
Release-Candidate-Branch	candidate_branch
Release-Candidate-Run	run_id
Release-Candidate-Run-Attempt	run_attempt
Release-Manifest-SHA256	manifest_sha256
Release-SHA256SUMS-SHA256	sha256sums_sha256
Release-Storage	storage'

# rf_tag_message <promotion-record.json>: prints the tag message.
rf_tag_message() {
  local rec="$1"
  rf_schema_check promotion-record "${rec}" || return 1
  printf 'release-flow %s %s\n\nPromoted by release-flow.\n\n' "$(jq -r .project "${rec}")" "$(jq -r .version "${rec}")"
  printf '%s\n' "${RF_TAG_TRAILERS}" | while IFS=$'\t' read -r key field; do
    printf '%s: %s\n' "${key}" "$(jq -r --arg f "${field}" '.[$f] | tostring' "${rec}")"
  done
}

# rf_tag_parse <tag-object>: strict parse of an annotated tag into a
# promotion-record JSON document on stdout. Fails (reason on stderr) on any
# deviation: not a tag object, a tag name or target that disagrees with the
# trailers, missing/duplicate/unknown trailers, or invalid values.
rf_tag_parse() {
  local obj="$1" raw header body subject tag_name tag_type tag_target trailers json tmp
  if [[ "$(git cat-file -t "${obj}" 2>/dev/null)" != "tag" ]]; then
    echo "${obj} is not an annotated tag object" >&2
    return 1
  fi
  raw="$(git cat-file tag "${obj}")" || return 1
  header="$(printf '%s\n' "${raw}" | awk 'NF == 0 { exit } { print }')"
  body="$(printf '%s\n' "${raw}" | awk 'f { print } NF == 0 && !f { f = 1 }' \
    | sed -E '/^-----BEGIN (SSH|PGP) SIGNATURE-----$/,$d')"
  tag_target="$(printf '%s\n' "${header}" | sed -n 's/^object //p')"
  tag_type="$(printf '%s\n' "${header}" | sed -n 's/^type //p')"
  tag_name="$(printf '%s\n' "${header}" | sed -n 's/^tag //p')"
  subject="$(printf '%s\n' "${body}" | head -n 1)"
  trailers="$(printf '%s\n' "${body}" | git interpret-trailers --parse)"
  if ! json="$(printf '%s\n' "${trailers}" | RF_TAG_TRAILERS="${RF_TAG_TRAILERS}" jq -R -s '
      ($ENV.RF_TAG_TRAILERS | split("\n") | map(split("\t") | {key: .[0], value: .[1]}) | from_entries) as $map
      | split("\n") | map(select(length > 0))
      | map(capture("^(?<k>[A-Za-z0-9-]+): (?<v>.*)$") // error("malformed trailer line"))
      | (map(.k) | group_by(.) | map(select(length > 1) | .[0])) as $dups
      | if ($dups | length) > 0 then error("duplicate trailers: " + ($dups | join(","))) else . end
      | (map(.k) - ($map | keys)) as $unknown
      | if ($unknown | length) > 0 then error("unknown trailers: " + ($unknown | join(","))) else . end
      | (($map | keys) - map(.k)) as $missing
      | if ($missing | length) > 0 then error("missing trailers: " + ($missing | join(","))) else . end
      | map({key: $map[.k], value: .v}) | from_entries
      | .run_attempt |= (if test("^[1-9][0-9]*$") then tonumber else error("invalid Release-Candidate-Run-Attempt") end)
      | {schema_version: 1, kind: "promotion-record"} + .' 2>&1)"; then
    echo "tag ${obj}: ${json}" >&2
    return 1
  fi
  tmp="$(mktemp)"
  printf '%s\n' "${json}" > "${tmp}"
  if ! rf_schema_check promotion-record "${tmp}"; then
    rm -f "${tmp}"
    echo "tag ${obj}: trailers do not form a valid promotion record" >&2
    return 1
  fi
  rm -f "${tmp}"
  if [[ "${tag_type}" != "commit" || "${tag_target}" != "$(printf '%s' "${json}" | jq -r .candidate_commit)" ]]; then
    echo "tag ${obj}: target ${tag_type} ${tag_target} differs from Release-Commit" >&2
    return 1
  fi
  if [[ "${tag_name}" != "$(printf '%s' "${json}" | jq -r .version)" ]]; then
    echo "tag ${obj}: tag name ${tag_name} differs from Release-Version" >&2
    return 1
  fi
  if [[ "${subject}" != "release-flow $(printf '%s' "${json}" | jq -r '.project + " " + .version')" ]]; then
    echo "tag ${obj}: unexpected subject: ${subject}" >&2
    return 1
  fi
  printf '%s\n' "${json}"
}

# rf_tag_verify_signature <tag-object> <mode> <repo> <commit> [allowed-signers-path]
#   github           GitHub reports the tag object verified
#   allowed-signers  git verify-tag against the allowed signers file as
#                    committed at <commit> (never a file the operator edits)
rf_tag_verify_signature() {
  local obj="$1" mode="$2" repo="$3" commit="$4" path="${5:-}" signers rc
  case "${mode}" in
    github)
      if ! rf_gh_tag_verified "${repo}" "${obj}"; then
        echo "GitHub does not report tag object ${obj} as verified" >&2
        return 1
      fi
      ;;
    allowed-signers)
      [[ -n "${path}" ]] || { echo "allowed-signers mode needs promotion.allowed_signers" >&2; return 1; }
      signers="$(mktemp)"
      if ! git show "${commit}:${path}" > "${signers}" 2>/dev/null; then
        rm -f "${signers}"
        echo "allowed signers file ${path} is missing at ${commit}" >&2
        return 1
      fi
      rc=0
      git -c gpg.ssh.allowedSignersFile="${signers}" verify-tag "${obj}" >/dev/null 2>&1 || rc=$?
      rm -f "${signers}"
      if (( rc != 0 )); then
        echo "tag object ${obj} has no valid signature from ${path} at ${commit}" >&2
        return 1
      fi
      ;;
    *)
      echo "unknown signature verification mode: ${mode}" >&2
      return 1
      ;;
  esac
}

# rf_tag_create <version> <commit> <message-file>: local signed annotated tag.
rf_tag_create() {
  git tag -s -a "$1" -F "$3" "$2"
}
