#!/usr/bin/env bash
# Discover candidates, or explicitly prune completed disposable candidates.
# Default and --prune defaults are read-only. No adapter is executed.
# bash 3.2 compatible. Exit: 0 ok, 1 evidence failure, 2 usage, 5 race/refusal.
set -euo pipefail
# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/schema.sh
source "${RF_SCRIPTS}/lib/schema.sh"
# shellcheck source=scripts/lib/github.sh
source "${RF_SCRIPTS}/lib/github.sh"

usage() { rf_die 'Usage: release-candidates.sh [--project-dir DIR] [--json] [--prune [--dry-run|--apply]]' 2; }
project_dir=.
json=false
prune=false
apply=false
choice=''
while (( $# )); do
  case "$1" in
    --project-dir) [[ $# -ge 2 ]] || usage; project_dir="$2"; shift 2 ;;
    --json) json=true; shift ;;
    --prune) prune=true; shift ;;
    --dry-run|--apply)
      [[ -z "$choice" ]] || usage
      choice="$1"; [[ "$1" != --apply ]] || apply=true; shift ;;
    *) usage ;;
  esac
done
[[ "$prune" == true || -z "$choice" ]] || usage
rf_require_tools git jq gh
top="$(git -C "$project_dir" rev-parse --show-toplevel)" || rf_die 'Not a Git work tree' 2
cd "$top"
rf_schema_check config .release-flow.json || rf_die 'Invalid .release-flow.json' 1
rf_config_load_text "$(cat .release-flow.json)"
rf_git_auth_env
project="$(rf_cfg .project)"
repository="$(rf_cfg .repository)"
remote="$(rf_cfg .remote)"
workflow="$(rf_cfg .promotion.candidate_workflow)"
workflow="${workflow:-.github/workflows/candidate.yml}"
job="$(rf_cfg .promotion.required_job)"
job="${job:-Candidate OK}"
[[ -n "$repository" ]] || rf_die 'Candidate discovery requires repository in .release-flow.json' 1

# Ref evidence and CI must belong to the same repository. Reject ambiguous
# aliases, credential-bearing URLs, and multiple push destinations for pruning.
remote_repository() {
  local url="$1" path
  case "$url" in
    https://github.com/*) path="${url#https://github.com/}" ;;
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%/}"; path="${path%.git}"
  [[ "$path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
  printf '%s' "$path" | tr '[:upper:]' '[:lower:]'
}
expected_repo="$(printf '%s' "$repository" | tr '[:upper:]' '[:lower:]')"
[[ "$(remote_repository "$(git remote get-url "$remote")")" == "$expected_repo" ]] \
  || rf_die 'Source remote must be a canonical github.com URL matching repository' 1
if [[ "$apply" == true ]]; then
  push_urls="$(git remote get-url --push --all "$remote")"
  [[ "$push_urls" != *$'\n'* && "$(remote_repository "$push_urls")" == "$expected_repo" ]] \
    || rf_die 'Pruning requires one canonical github.com push URL matching repository' 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git ls-remote --heads "$remote" > "$WORK/heads" || rf_die 'Cannot read remote branches' 1

# Pagination is required: an older queued run must not disappear behind a page.
branch_runs() {
  local encoded
  encoded="$(jq -rn --arg b "$1" '$b|@uri')"
  gh api --paginate "repos/$repository/actions/runs?branch=$encoded&per_page=100" > "$WORK/pages" || return 1
  jq -es 'if length>0 and all(.[]; (.workflow_runs|type)=="array")
    then [.[].workflow_runs[]] | if all(.[]; type=="object" and (.status|type)=="string") then . else error("invalid run") end else error("invalid runs response") end' "$WORK/pages"
}
trailer() { git show -s --format="%(trailers:key=$2,valueonly)" "$1" | sed '/^$/d'; }

candidate_row() {
  local branch="$1" commit="$2" version='' mode='' base='' base_branch='' base_status=unknown
  local validation=unknown retention=unknown promotion=unpromoted reason=invalid_identity safe=false
  local runs run='{}' run_id='' attempt='' run_url='' active=true identity=false records key record=''
  local status historical ledger binding parent suffix
  [[ "$commit" =~ $RF_RE_COMMIT ]] || return 1
  if [[ "$branch" =~ ^release/(test/)?([0-9]+\.[0-9]+\.[0-9]+)-([0-9a-f]{12})$ ]]; then
    mode=production; [[ -z "${BASH_REMATCH[1]}" ]] || mode=test-only
    version="${BASH_REMATCH[2]}"; suffix="${BASH_REMATCH[3]}"
    rf_git_fetch "$remote" "$commit" || return 1
    base="$(trailer "$commit" Release-Base-Commit)"
    base_branch="$(trailer "$commit" Release-Base-Branch)"
    parent="$(git rev-list --parents -n 1 "$commit")"
    if rf_semver_valid "$version" && [[ "$base" =~ $RF_RE_COMMIT && "${base:0:12}" == "$suffix" &&
        "$parent" == "$commit $base" && "$(trailer "$commit" Release-Project)" == "$project" &&
        "$(trailer "$commit" Release-Version)" == "$version" && "$(trailer "$commit" Release-Mode)" == "$mode" ]]; then
      git show "$commit:.release-flow.json" > "$WORK/config" || return 1
      if rf_schema_check config "$WORK/config" >/dev/null 2>&1 &&
         jq -e --arg p "$project" --arg r "$repository" --arg b "$base_branch" --arg mode "$mode" \
           '.project==$p and .repository==$r and (if $mode=="production" then .production_base else .test_base end)==$b' "$WORK/config" >/dev/null; then
        identity=true
      fi
    fi
  fi
  if [[ "$identity" == true ]]; then
    if [[ "$(rf_ls_remote_value "$(cat "$WORK/heads")" "refs/heads/$base_branch")" == "$base" ]]; then base_status=current; else base_status=stale; fi
    runs="$(branch_runs "$branch")" || { echo "Cannot establish CI state for $branch; no branches deleted" >&2; return 1; }
    # Any unknown or unfinished status is active, regardless of workflow name.
    active="$(printf '%s' "$runs" | jq -r 'any(.[];.status!="completed")')"
    run="$(printf '%s' "$runs" | jq -c --arg c "$commit" --arg b "$branch" --arg r "$repository" --arg w "$workflow" '
      [.[]|select(.head_sha==$c and .head_branch==$b and .event=="push" and .path==$w
        and .repository.full_name==$r and .head_repository.full_name==$r)]
      | if length==0 then {} else max_by(.run_number) end')"
    run_id="$(printf '%s' "$run" | jq -r '.id // empty')"
    attempt="$(printf '%s' "$run" | jq -r '.run_attempt // empty')"
    run_url="$(printf '%s' "$run" | jq -r '.html_url // empty')"
    validation=missing
    if [[ -n "$run_id" ]]; then
      validation="$(printf '%s' "$run" | jq -r 'if .status!="completed" then "active" else (.conclusion // "unknown") end')"
      if [[ "$validation" == success ]]; then
        if ! rf_gh_run_pipeline "$run" "$(jq -r '.pipeline.repository // empty' "$WORK/config")" "$(jq -r '.pipeline.sha // empty' "$WORK/config")" >/dev/null 2>&1 ||
           ! rf_gh_job_ok "$repository" "$run_id" "$attempt" "$job" >/dev/null 2>&1; then validation=unverified; fi
      fi
    fi
    retention=not_configured
    if [[ "$mode" == test-only ]]; then retention=not_applicable
    elif [[ -n "$(rf_storage_uri)" ]]; then
      retention=missing
      records="$(rf_storage list "candidates/$project/$commit/")" || return 1
      while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        rf_storage get-record "$key" "$WORK/record" --kind candidate-record || return 1
        if jq -e --arg p "$project" --arg r "$repository" --arg c "$commit" --arg b "$base" --arg br "$branch" \
          --arg v "$version" --arg run "$run_id" '.project==$p and .repository==$r and .candidate_commit==$c and .base_commit==$b
          and .candidate_branch==$br and .version==$v and .run_id==$run' "$WORK/record" >/dev/null; then
          retention=retained; record="$key"
        fi
      done <<< "$records"
    fi
    reason=operator_decision_required
    if [[ "$active" == true ]]; then reason=active_ci
    elif [[ -z "$run_id" ]]; then reason=no_validation_run
    elif [[ "$mode" == test-only ]]; then
      promotion=not_promotable; safe=true; reason=completed_test_candidate
    else
      status="$(bash "$RF_SCRIPTS/release-status.sh" --project-dir "$top" "$version" --json 2>"$WORK/status-error")" || return 1
      promotion="$(printf '%s' "$status" | jq -r .state)"
      # A current config cannot waive publishers required by the released commit.
      if printf '%s' "$status" | jq -e --arg c "$commit" '.state=="PUBLISHED" and .candidate_commit==$c and .binding==true
          and all(.channels[]; .lock==null or .lock.expired==true)' >/dev/null; then
        historical="$(jq -c '.publishers // {}' "$WORK/config")"
        ledger="$(bash "$RF_SCRIPTS/publication/ledger.sh" --uri "$(rf_storage_uri)" --region "$(rf_cfg .storage.region)" \
          --endpoint "$(rf_cfg .storage.endpoint)" status --project "$project" --version "$version")" || return 1
        rf_storage get-record "releases/$project/$version.json" "$WORK/binding" --kind release-binding || return 1
        binding="$(cat "$WORK/binding")"
        if [[ "$(rf_publication_state "$ledger" "$historical")" == PUBLISHED ]] &&
          printf '%s' "$binding" | jq -e --arg c "$commit" --arg r "$repository" --arg m "$(printf '%s' "$status" | jq -r .manifest_sha256)" \
            '.candidate_commit==$c and .repository==$r and .manifest_sha256==$m' >/dev/null; then
          safe=true; reason=fully_published
        fi
      fi
    fi
  fi
  # Even a candidate-looking name cannot authorize deletion of an integration
  # branch. Respect both rulesets and legacy branch protection before eligibility.
  if [[ "$branch" == main || "$branch" == develop || "$branch" == sandbox ||
        "$branch" == "$(rf_cfg .production_base)" || "$branch" == "$(rf_cfg .test_base)" ||
        "$branch" == "$(rf_cfg .promotion.main_branch)" ]]; then
    safe=false; reason=integration_branch
  elif [[ "$safe" == true ]]; then
    local encoded rc=0
    encoded="$(jq -rn --arg b "$branch" '$b|@uri')"
    gh api "repos/$repository/rules/branches/$encoded" > "$WORK/rules" || return 1
    if ! jq -e 'type=="array" and all(.[];type=="object" and (.type|type)=="string" and .type!="deletion")' "$WORK/rules" >/dev/null; then
      safe=false; reason=deletion_protected
    else
      gh api "repos/$repository/branches/$encoded/protection" > "$WORK/protection" 2>"$WORK/protection-error" || rc=$?
      if (( rc==0 )); then safe=false; reason=legacy_protection
      elif ! jq -e '.status=="404"' "$WORK/protection" >/dev/null 2>&1; then
        safe=false; reason=protection_unavailable
      fi
    fi
  fi
  jq -n --arg version "$version" --arg branch "$branch" --arg commit "$commit" --arg mode "$mode" \
    --arg base "$base" --arg base_branch "$base_branch" --arg base_status "$base_status" --arg validation "$validation" \
    --arg run "$run_id" --arg attempt "$attempt" --arg url "$run_url" --arg retention "$retention" --arg record "$record" \
    --arg promotion "$promotion" --arg reason "$reason" --argjson safe "$safe" \
    '{version:$version,branch:$branch,commit:$commit,mode:$mode,base_commit:$base,base_branch:$base_branch,base_status:$base_status,
      validation:{state:$validation,run_id:$run,run_attempt:$attempt,url:$url},retention:{state:$retention,record:$record},
      promotion:$promotion,safe_to_delete:$safe,reason:$reason}'
}

: > "$WORK/rows"
while read -r commit ref; do
  case "$ref" in refs/heads/release/*) ;; *) continue ;; esac
  candidate_row "${ref#refs/heads/}" "$commit" >> "$WORK/rows" || rf_die 'Candidate evidence unavailable; nothing deleted' 1
done < "$WORK/heads"
jq -s 'sort_by(.version,.branch)' "$WORK/rows" > "$WORK/items"

if [[ "$apply" == true ]]; then
  leases=(); deletes=()
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    branch="$(printf '%s' "$row" | jq -r .branch)"
    commit="$(printf '%s' "$row" | jq -r .commit)"
    # Only canonical release candidates can ever enter this set.
    [[ "$branch" =~ ^release/(test/)?[0-9]+\.[0-9]+\.[0-9]+-[0-9a-f]{12}$ ]] || rf_die 'Unsafe prune target' 5
    current="$(git ls-remote --heads "$remote" "refs/heads/$branch")" || rf_die 'Cannot recheck candidate ref' 1
    [[ "$(rf_ls_remote_value "$current" "refs/heads/$branch")" == "$commit" ]] || rf_die "Candidate changed: $branch; nothing deleted" 5
    fresh="$(candidate_row "$branch" "$commit")" || rf_die 'Cannot recheck candidate evidence; nothing deleted' 1
    [[ "$(printf '%s' "$fresh" | jq -r .safe_to_delete)" == true ]] || rf_die "Candidate became ineligible: $branch; nothing deleted" 5
    leases+=("--force-with-lease=refs/heads/$branch:$commit")
    deletes+=(":refs/heads/$branch")
  done <<< "$(jq -c '.[]|select(.safe_to_delete)' "$WORK/items")"
  if (( ${#deletes[@]} )); then
    # Atomic ref deletion and exact leases prevent partial deletion/ref races.
    git push --atomic --no-follow-tags --porcelain "${leases[@]}" "$remote" "${deletes[@]}" >&2 \
      || rf_die 'Prune rejected; the atomic push deleted nothing' 5
  fi
fi
if [[ "$json" == true ]]; then
  jq -n --argjson prune "$prune" --argjson apply "$apply" --slurpfile items "$WORK/items" \
    '{schema_version:1,kind:(if $prune then "candidate-prune" else "candidate-list" end),applied:$apply,items:$items[0]}'
else
  printf '%-9s %-11s %-12s %-16s %-7s %-12s %-6s %-40s %s\n' VERSION MODE VALIDATION RETENTION BASE PROMOTION DELETE COMMIT BRANCH
  jq -r '.[]|[.version,.mode,.validation.state,.retention.state,.base_status,.promotion,(if .safe_to_delete then "yes" else "no" end),.commit,.branch]|@tsv' "$WORK/items" \
    | while IFS=$'\t' read -r v m va re ba pr de co br; do printf '%-9s %-11s %-12s %-16s %-7s %-12s %-6s %-40s %s\n' "$v" "$m" "$va" "$re" "$ba" "$pr" "$de" "$co" "$br"; done
  if [[ "$prune" == true && "$apply" != true ]]; then echo 'Dry run: only DELETE=yes candidates would be removed. Use --apply explicitly.'; fi
fi
