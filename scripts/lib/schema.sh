# shellcheck shell=bash
# Strict JSON schemas for every document release-flow passes between steps.
# Sourced, never executed. bash 3.2 compatible.
#
#   rf_schema_check <kind> <file>   0 valid, 1 invalid (errors on stderr)
#
# Kinds: config candidate-record release-binding promotion-record
#        publication-event publication-lock latest-pointer docs-marker

if [[ -n "${RF_SCHEMA_LOADED:-}" ]]; then
  return 0
fi
RF_SCHEMA_LOADED=1

RF_SCHEMA_DEFS='
def err(m): "schema error: " + m;
def str: type == "string";
def commit: str and test("^[0-9a-f]{40}$");
def digest: str and test("^[0-9a-f]{64}$");
def version: str and test("^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$");
def project: str and test("^[A-Za-z0-9][A-Za-z0-9._-]*$");
def repo: str and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$");
def runid: str and test("^[0-9]+$");
def posint: type == "number" and . >= 1 and floor == .;
def nonneg: type == "number" and . >= 0 and floor == .;
def nonempty: str and length > 0;
def branchname: str and test("^[A-Za-z0-9][A-Za-z0-9._/-]*$") and (test("\\.\\.|//|/$|\\.lock$") | not);
def tpl: str and length > 0 and (gsub("\\{(project|version)\\}"; "") | test("[{}]") | not);
def uri: str and test("^(file:///|s3://[a-z0-9][a-z0-9.-]*[a-z0-9](/|$))");
def exact($ks): if type != "object" then err("must be an object")
  elif (keys | sort) != ($ks | sort) then err("keys must be exactly " + ($ks | sort | join(",")) + " (got " + (keys | sort | join(",")) + ")")
  else empty end;
def allowed($ks): if type != "object" then err("must be an object")
  else ((keys - $ks) as $x | if ($x | length) > 0 then err("unknown keys: " + ($x | join(","))) else empty end) end;
def need(c; m): if c then empty else err(m) end;
def opt($k; c; m): if has($k) then (.[$k] | need(c; m)) else empty end;
def identity:
  (.project | need(project; "invalid project")),
  (.repository | need(repo; "invalid repository")),
  (.version | need(version; "invalid version")),
  (.candidate_commit | need(commit; "invalid candidate_commit")),
  (.base_commit | need(commit; "invalid base_commit")),
  (.candidate_branch | need(str and test("^release/(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)-[0-9a-f]{12}$"); "invalid candidate_branch")),
  (.run_id | need(runid; "invalid run_id")),
  (.run_attempt | need(posint; "invalid run_attempt")),
  (.manifest_sha256 | need(digest; "invalid manifest_sha256")),
  (.sha256sums_sha256 | need(digest; "invalid sha256sums_sha256")),
  (. as $d | if ($d.candidate_branch | str) and ($d.version | str) and ($d.candidate_branch | startswith("release/" + $d.version + "-") | not)
   then err("candidate_branch does not carry the version") else empty end),
  (. as $d | if ($d.candidate_branch | str) and ($d.base_commit | str) and ($d.candidate_branch | endswith("-" + ($d.base_commit[0:12])) | not)
   then err("candidate_branch does not carry the base commit prefix") else empty end);
'

RF_SCHEMA_CONFIG='
def publisher($name; $ks):
  .[$name] | if . == null then empty else
    allowed($ks),
    (if type == "object" then
      (.required | need(type == "boolean"; $name + ".required must be a boolean")),
      opt("artifact"; tpl; $name + ".artifact must be a {project}/{version} template"),
      opt("assets"; type == "array" and length > 0 and all(.[]; nonempty); $name + ".assets must be a non-empty string array"),
      opt("package"; nonempty; $name + ".package must be a string"),
      opt("index_url"; str and test("^(https|file)://"); $name + ".index_url must be https:// or file://"),
      opt("repository"; tpl; $name + ".repository must be a template string"),
      opt("tags"; type == "array" and length > 0 and all(.[]; tpl); $name + ".tags must be a non-empty template array"),
      opt("latest_tag"; nonempty and test("^[A-Za-z0-9_][A-Za-z0-9._-]*$"); $name + ".latest_tag must be a tag name"),
      opt("uri"; tpl and test("^(file:///|s3://)"); $name + ".uri must be file:/// or s3:// template"),
      opt("base_url"; str and test("^https?://"); $name + ".base_url must be an http(s) URL"),
      opt("latest"; type == "boolean"; $name + ".latest must be a boolean")
    else empty end)
  end;
allowed(["schema_version","project","adapter","remote","production_base","test_base","repository","promotion","storage","publishers","pipeline"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.project | need(project; "invalid project")),
(.adapter | need(nonempty; "invalid adapter")),
(.remote | need(nonempty; "invalid remote")),
(.production_base | need(branchname; "invalid production_base")),
(.test_base | need(branchname; "invalid test_base")),
opt("repository"; repo; "invalid repository"),
(if has("promotion") then .promotion |
  allowed(["main_branch","push_remote","candidate_workflow","required_job","signature_verification","allowed_signers","publisher_ref"]),
  (if type == "object" then
    opt("main_branch"; branchname; "invalid promotion.main_branch"),
    opt("push_remote"; nonempty; "invalid promotion.push_remote"),
    opt("candidate_workflow"; str and test("^\\.github/workflows/[A-Za-z0-9._-]+\\.ya?ml$"); "invalid promotion.candidate_workflow"),
    opt("required_job"; nonempty; "invalid promotion.required_job"),
    opt("signature_verification"; . == "github" or . == "allowed-signers"; "promotion.signature_verification must be github or allowed-signers"),
    opt("allowed_signers"; str and test("^\\.github/[A-Za-z0-9._/-]+$") and (test("\\.\\.") | not); "promotion.allowed_signers must be a path under .github/"),
    opt("publisher_ref"; branchname; "invalid promotion.publisher_ref"),
    (if .signature_verification == "allowed-signers" and (has("allowed_signers") | not)
     then err("promotion.allowed_signers is required for allowed-signers verification") else empty end)
  else empty end)
 else empty end),
(if has("storage") then .storage |
  allowed(["uri","region","endpoint"]),
  (if type == "object" then
    opt("uri"; uri; "storage.uri must be file:///abs or s3://bucket[/prefix]"),
    opt("region"; str; "storage.region must be a string"),
    opt("endpoint"; str and (. == "" or test("^https?://")); "storage.endpoint must be an http(s) URL")
  else empty end)
 else empty end),
(if has("publishers") then .publishers |
  allowed(["github-release","oci","crates-io","docs","helm"]),
  (if type == "object" then
    publisher("github-release"; ["required","assets"]),
    publisher("crates-io"; ["required","artifact","package","index_url"]),
    publisher("oci"; ["required","artifact","repository","tags","latest_tag"]),
    publisher("docs"; ["required","artifact","uri","latest"]),
    publisher("helm"; ["required","artifact","uri","base_url"]),
    (if (.oci // null) != null then .oci | need(has("artifact") and has("repository") and has("tags"); "oci requires artifact, repository and tags") else empty end),
    (if (.["crates-io"] // null) != null then .["crates-io"] | need(has("artifact"); "crates-io requires artifact") else empty end),
    (if (.docs // null) != null then .docs | need(has("artifact") and has("uri"); "docs requires artifact and uri") else empty end),
    (if (.helm // null) != null then .helm | need(has("artifact") and has("uri") and has("base_url"); "helm requires artifact, uri and base_url") else empty end)
  else empty end)
 else empty end),
(if has("pipeline") then .pipeline | exact(["repository","sha"]),
  (if type == "object" then (.repository | need(repo; "invalid pipeline.repository")),
                             (.sha | need(commit; "invalid pipeline.sha")) else empty end)
 else empty end)
'

RF_SCHEMA_CANDIDATE_RECORD='
exact(["schema_version","kind","project","repository","version","mode","candidate_commit","base_commit","candidate_branch","run_id","run_attempt","manifest_sha256","sha256sums_sha256"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "candidate-record"; "kind must be candidate-record")),
(.mode | need(. == "production"; "mode must be production")),
identity
'

RF_SCHEMA_PROMOTION_RECORD='
exact(["schema_version","kind","project","repository","version","candidate_commit","base_commit","candidate_branch","run_id","run_attempt","manifest_sha256","sha256sums_sha256","storage"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "promotion-record"; "kind must be promotion-record")),
(.storage | need(nonempty and (test("[[:space:]]") | not); "invalid storage")),
identity
'

RF_SCHEMA_RELEASE_BINDING='
exact(["schema_version","kind","project","repository","version","candidate_commit","base_commit","candidate_branch","run_id","run_attempt","manifest_sha256","sha256sums_sha256","storage","tag","tag_object","storage_uri"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "release-binding"; "kind must be release-binding")),
(.storage | need(nonempty; "invalid storage")),
(.tag | need(version; "invalid tag")),
(if .tag != .version then err("tag must equal version") else empty end),
(.tag_object | need(commit; "invalid tag_object")),
(.storage_uri | need(uri; "invalid storage_uri")),
identity
'

RF_SCHEMA_PUBLICATION_EVENT='
exact(["schema_version","kind","project","version","candidate_commit","manifest_sha256","channel","attempt_id","seq","state","at","actor","run_url","observed","error_class","error"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "publication-event"; "kind must be publication-event")),
(.project | need(project; "invalid project")),
(.version | need(version; "invalid version")),
(.candidate_commit | need(commit; "invalid candidate_commit")),
(.manifest_sha256 | need(digest; "invalid manifest_sha256")),
(.channel | need(. == "github-release" or . == "oci" or . == "crates-io" or . == "docs" or . == "helm"; "invalid channel")),
(.attempt_id | need(str and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"); "invalid attempt_id")),
(.seq | need(posint and . <= 9999; "invalid seq")),
(.state | need(. == "running" or . == "succeeded" or . == "failed"; "state must be running, succeeded or failed")),
(.at | need(str and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"); "invalid at")),
(.actor | need(str and test("^(local:[^[:space:]]+|gha:[0-9]+/[0-9]+)$"); "invalid actor")),
(.run_url | need(str; "run_url must be a string")),
(.observed | need(type == "object"; "observed must be an object")),
(.error_class | need(. == null or . == "transient" or . == "conflict" or . == "missing-source" or . == "integrity" or . == "config" or . == "auth"; "invalid error_class")),
(.error | need(. == null or str; "error must be a string or null")),
(if .state == "failed" and .error_class == null then err("failed events need an error_class") else empty end),
(if .state != "failed" and .error_class != null then err("only failed events carry an error_class") else empty end)
'

RF_SCHEMA_PUBLICATION_LOCK='
exact(["schema_version","kind","project","version","channel","attempt_id","acquired_at","expires_at"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "publication-lock"; "kind must be publication-lock")),
(.project | need(project; "invalid project")),
(.version | need(version; "invalid version")),
(.channel | need(. == "github-release" or . == "oci" or . == "crates-io" or . == "docs" or . == "helm"; "invalid channel")),
(.attempt_id | need(str and test("^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$"); "invalid attempt_id")),
(.acquired_at | need(nonneg; "invalid acquired_at")),
(.expires_at | need(nonneg; "invalid expires_at"))
'

RF_SCHEMA_LATEST_POINTER='
exact(["schema_version","kind","project","channel","version","digest","manifest_sha256"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "latest-pointer"; "kind must be latest-pointer")),
(.project | need(project; "invalid project")),
(.channel | need(. == "oci" or . == "docs"; "invalid channel")),
(.version | need(version; "invalid version")),
(.digest | need(str and test("^(sha256:)?[0-9a-f]{64}$"); "invalid digest")),
(.manifest_sha256 | need(digest; "invalid manifest_sha256"))
'

RF_SCHEMA_DOCS_MARKER='
exact(["schema_version","kind","project","version","manifest_sha256","artifact_sha256","files"]),
(.schema_version | need(. == 1; "schema_version must be 1")),
(.kind | need(. == "docs-marker"; "kind must be docs-marker")),
(.project | need(project; "invalid project")),
(.version | need(version; "invalid version")),
(.manifest_sha256 | need(digest; "invalid manifest_sha256")),
(.artifact_sha256 | need(digest; "invalid artifact_sha256")),
(.files | need(posint; "invalid files"))
'

# rf_schema_check <kind> <file>
rf_schema_check() {
  local kind="$1" file="$2" program errors
  case "${kind}" in
    config) program="${RF_SCHEMA_CONFIG}" ;;
    candidate-record) program="${RF_SCHEMA_CANDIDATE_RECORD}" ;;
    promotion-record) program="${RF_SCHEMA_PROMOTION_RECORD}" ;;
    release-binding) program="${RF_SCHEMA_RELEASE_BINDING}" ;;
    publication-event) program="${RF_SCHEMA_PUBLICATION_EVENT}" ;;
    publication-lock) program="${RF_SCHEMA_PUBLICATION_LOCK}" ;;
    latest-pointer) program="${RF_SCHEMA_LATEST_POINTER}" ;;
    docs-marker) program="${RF_SCHEMA_DOCS_MARKER}" ;;
    *)
      printf 'schema error: unknown kind %s\n' "${kind}" >&2
      return 1
      ;;
  esac
  if [[ ! -f "${file}" ]]; then
    printf 'schema error: %s: no such file\n' "${file}" >&2
    return 1
  fi
  if ! errors="$(jq -r "${RF_SCHEMA_DEFS} if type != \"object\" then err(\"document must be a JSON object\") else ${program} end" "${file}" 2>&1)"; then
    printf 'schema error (%s): malformed JSON: %s\n' "${kind}" "${file}" >&2
    return 1
  fi
  # A file holding several JSON values is not a single document.
  if [[ "$(jq -s 'length' "${file}" 2>/dev/null)" != "1" ]]; then
    printf 'schema error (%s): %s must hold exactly one JSON document\n' "${kind}" "${file}" >&2
    return 1
  fi
  if [[ -n "${errors}" ]]; then
    printf '%s\n' "${errors}" | sed "s|^|${kind}: |" >&2
    return 1
  fi
  return 0
}
