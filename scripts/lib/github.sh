# shellcheck shell=bash
# GitHub evidence queries through the gh CLI. Sourced, never executed.
# Endpoint strings are canonical (the test mock matches them exactly).
# bash 3.2 compatible.

if [[ -n "${RF_GITHUB_LOADED:-}" ]]; then
  return 0
fi
RF_GITHUB_LOADED=1

# rf_gh_api <endpoint>: response JSON on stdout; non-zero on any failure.
rf_gh_api() {
  gh api "$1"
}

# rf_gh_candidate_run <repo> <workflow-path> <commit> <branch> [run-id]
# Prints the selected run (JSON) for the candidate commit: the push run of the
# exact workflow file on the exact branch and repository, highest run_number
# (or the given run id). Fails (with a reason on stderr) unless it completed
# successfully.
rf_gh_candidate_run() {
  local repo="$1" wf_path="$2" commit="$3" branch="$4" want_run="${5:-}" resp run
  if ! resp="$(rf_gh_api "repos/${repo}/actions/workflows/$(basename "${wf_path}")/runs?head_sha=${commit}&event=push&per_page=100")"; then
    echo "no ${wf_path} run found for ${commit} (GitHub API query failed)" >&2
    return 1
  fi
  run="$(printf '%s' "${resp}" | jq -c --arg path "${wf_path}" --arg sha "${commit}" --arg branch "${branch}" \
      --arg repo "${repo}" --arg want "${want_run}" '
    [ (.workflow_runs // [])[]
      | select(.path == $path and .event == "push" and .head_sha == $sha and .head_branch == $branch
               and .repository.full_name == $repo and .head_repository.full_name == $repo)
      | select($want == "" or (.id | tostring) == $want) ]
    | if length == 0 then empty else max_by(.run_number) end' 2>/dev/null || true)"
  if [[ -z "${run}" ]]; then
    echo "no push run of ${wf_path} on ${branch} at ${commit} in ${repo}${want_run:+ with id ${want_run}}" >&2
    return 1
  fi
  if [[ "$(printf '%s' "${run}" | jq -r '.status + "/" + (.conclusion // "none")')" != "completed/success" ]]; then
    echo "run $(printf '%s' "${run}" | jq -r .id) is $(printf '%s' "${run}" | jq -r '.status + "/" + (.conclusion // "none")'), not completed/success" >&2
    return 1
  fi
  printf '%s\n' "${run}"
}

# rf_gh_job_ok <repo> <run-id> <attempt> <job-name>: the job concluded success
# in that attempt.
rf_gh_job_ok() {
  local resp verdict
  if ! resp="$(rf_gh_api "repos/$1/actions/runs/$2/attempts/$3/jobs?per_page=100")"; then
    echo "cannot read jobs of run $2 attempt $3" >&2
    return 1
  fi
  verdict="$(printf '%s' "${resp}" | jq -r --arg n "$4" '
    [ (.jobs // [])[] | select(.name == $n) ] as $j
    | if ($j | length) == 0 then "job \"" + $n + "\" not found"
      elif all($j[]; .conclusion == "success") then "ok"
      else "job \"" + $n + "\" concluded " + ([$j[].conclusion // "none"] | join(",")) end' 2>/dev/null || echo "unreadable jobs response")"
  if [[ "${verdict}" != "ok" ]]; then
    echo "${verdict} in run $2 attempt $3" >&2
    return 1
  fi
}

# rf_gh_candidate_artifact <repo> <run-id> <commit>: prints "<name> <attempt>"
# of the non-expired candidate-<commit>-<attempt> artifact with the highest
# attempt.
rf_gh_candidate_artifact() {
  local resp sel
  if ! resp="$(rf_gh_api "repos/$1/actions/runs/$2/artifacts?per_page=100")"; then
    echo "cannot list artifacts of run $2" >&2
    return 1
  fi
  sel="$(printf '%s' "${resp}" | jq -r --arg c "$3" '
    [ (.artifacts // [])[]
      | select(.expired == false and (.name | test("^candidate-" + $c + "-[0-9]+$")))
      | {name, attempt: (.name | ltrimstr("candidate-" + $c + "-") | tonumber)} ]
    | if length == 0 then empty else (max_by(.attempt) | "\(.name) \(.attempt)") end' 2>/dev/null || true)"
  if [[ -z "${sel}" ]]; then
    echo "candidate artifacts expired or missing for run $2; prepare a new candidate" >&2
    return 1
  fi
  printf '%s\n' "${sel}"
}

# rf_gh_download_artifact <repo> <run-id> <name> <dir>
rf_gh_download_artifact() {
  gh run download "$2" --repo "$1" --name "$3" --dir "$4" >&2
}

# rf_gh_tag_verified <repo> <tag-object>: GitHub verified the tag signature.
rf_gh_tag_verified() {
  local resp
  resp="$(rf_gh_api "repos/$1/git/tags/$2")" || return 1
  [[ "$(printf '%s' "${resp}" | jq -r '.verification.verified // false')" == "true" ]]
}

# rf_gh_protection_ok <repo> <main> <develop> <required-job>: rules on main
# (deletion, non_fast_forward, required status check), develop (deletion,
# non_fast_forward) and an active tag ruleset (update, deletion) covering
# refs/tags/*.*.*. Prints the first gap on stderr.
rf_gh_protection_ok() {
  local repo="$1" main="$2" develop="$3" job="$4" rules ids id rs ok=false
  if ! rules="$(rf_gh_api "repos/${repo}/rules/branches/${main}")"; then
    echo "cannot read rules for ${main}" >&2
    return 1
  fi
  if ! printf '%s' "${rules}" | jq -e --arg job "${job}" '
      ([.[].type] | index("deletion") != null and index("non_fast_forward") != null)
      and any(.[]; .type == "required_status_checks"
              and any(.parameters.required_status_checks[]?; .context == $job))' >/dev/null 2>&1; then
    echo "${main} lacks deletion, non_fast_forward or the required \"${job}\" status check" >&2
    return 1
  fi
  if ! rules="$(rf_gh_api "repos/${repo}/rules/branches/${develop}")"; then
    echo "cannot read rules for ${develop}" >&2
    return 1
  fi
  if ! printf '%s' "${rules}" | jq -e '[.[].type] | index("deletion") != null and index("non_fast_forward") != null' >/dev/null 2>&1; then
    echo "${develop} lacks deletion or non_fast_forward rules" >&2
    return 1
  fi
  if ! ids="$(rf_gh_api "repos/${repo}/rulesets?includes_parents=true&per_page=100" \
      | jq -r '.[] | select(.target == "tag" and .enforcement == "active") | .id' 2>/dev/null)"; then
    echo "cannot list rulesets" >&2
    return 1
  fi
  for id in ${ids}; do
    rs="$(rf_gh_api "repos/${repo}/rulesets/${id}")" || continue
    if printf '%s' "${rs}" | jq -e '
        (.enforcement == "active")
        and any(.conditions.ref_name.include[]?; . == "refs/tags/*.*.*" or . == "refs/tags/*" or . == "~ALL")
        and ([.rules[]?.type] | index("update") != null and index("deletion") != null)' >/dev/null 2>&1; then
      ok=true
      break
    fi
  done
  if [[ "${ok}" != "true" ]]; then
    echo "no active tag ruleset with update and deletion rules covers refs/tags/*.*.*" >&2
    return 1
  fi
}

# rf_gh_signing_key_registered <format> <public-key-or-key-id>: the key is a
# signing key of the authenticated GitHub user.
rf_gh_signing_key_registered() {
  local format="$1" key="$2" login resp
  login="$(rf_gh_api user | jq -r '.login // empty' 2>/dev/null || true)"
  if [[ -z "${login}" ]]; then
    echo "cannot determine the authenticated GitHub user" >&2
    return 1
  fi
  if [[ "${format}" == "ssh" ]]; then
    resp="$(rf_gh_api "users/${login}/ssh_signing_keys")" || return 1
    printf '%s' "${resp}" | jq -e --arg k "${key}" \
      'any(.[]; (.key | split(" ")[0:2] | join(" ")) == ($k | split(" ")[0:2] | join(" ")))' >/dev/null 2>&1 || {
      echo "signing key is not registered as an SSH signing key of GitHub user ${login}" >&2
      return 1
    }
  else
    resp="$(rf_gh_api "users/${login}/gpg_keys")" || return 1
    printf '%s' "${resp}" | jq -e --arg k "${key}" '
      ($k | ascii_upcase | .[-16:]) as $id
      | any(.[]; ((.key_id // "") | ascii_upcase) == $id
                 or any(.subkeys[]?; ((.key_id // "") | ascii_upcase) == $id))' >/dev/null 2>&1 || {
      echo "signing key ${key} is not a GPG key of GitHub user ${login}" >&2
      return 1
    }
  fi
}
