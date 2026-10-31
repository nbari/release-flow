#!/usr/bin/env bash
# GitHub Release channel. Invoked by publication/publish.sh:
#
#   github-release.sh observe   prints {"state":"absent|partial|complete|conflict","detail":{...}}
#   github-release.sh apply     draft -> exact assets -> publish (exit 0, 1, 4 or 5)
#
# Desired assets: the manifest artifacts matching publishers.github-release.assets
# (globs, default "*"), plus SHA256SUMS and manifest.json, each with its pinned
# sha256. A draft is repaired (stray or wrong-digest assets deleted, missing
# ones uploaded, never --clobber); a published release is never modified,
# except for GitHub's "latest" marker: a published release whose marker is
# wrong (it should be latest and is not, or it is latest while a newer
# promoted release is published) observes as partial, and apply moves the
# marker. Releases are listed across every page (drafts have no tag lookup).
# Inputs (environment): RF_RELEASE_DIR RF_CHANNEL_CONFIG RF_IS_LATEST
# RF_PROJECT RF_VERSION RF_PROJECT_DIR RF_CONFIG_JSON.
# Must stay compatible with bash 3.2 (macOS default).
set -euo pipefail

# shellcheck source=scripts/lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

action="${1:-}"
version="${RF_VERSION:?}"
repo="$(rf_cfg .repository)"
artifacts="${RF_RELEASE_DIR:?}/artifacts"
manifest="${artifacts}/manifest.json"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# desired assets as [{name, sha256}]
desired_json() {
  local globs name sha g out=""
  globs="$(printf '%s' "${RF_CHANNEL_CONFIG:-{\}}" | jq -r '(.assets // ["*"])[]')"
  while IFS=$'\t' read -r name sha; do
    [[ -n "${name}" ]] || continue
    while IFS= read -r g; do
      # shellcheck disable=SC2053
      if [[ -n "${g}" && "${name}" == ${g} ]]; then
        out+="${name}"$'\t'"${sha}"$'\n'
        break
      fi
    done <<< "${globs}"
  done <<< "$(jq -r '.artifacts[] | [.name, .sha256] | @tsv' "${manifest}")"
  out+="SHA256SUMS"$'\t'"$(rf_sha256_file "${artifacts}/SHA256SUMS")"$'\n'
  out+="manifest.json"$'\t'"$(rf_sha256_file "${manifest}")"$'\n'
  printf '%s' "${out}" | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {name: .[0], sha256: .[1]}) | sort_by(.name)'
}

# list_releases: every release of the repository (all pages, drafts included)
list_releases() {
  local out
  out="$(gh api --paginate "repos/${repo}/releases?per_page=100")" || { echo "cannot list releases of ${repo}" >&2; return 1; }
  # --paginate prints one JSON array per page
  printf '%s' "${out}" | jq -cs 'map(.[]?)'
}

# latest_plan <releases-json> <is-latest>: prints the tag that must receive
# GitHub's latest marker for this published version to be right, or nothing.
latest_plan() {
  local rels="$1" is_latest="$2" gh_latest t
  gh_latest="$(gh api "repos/${repo}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [[ "${is_latest}" == "true" ]]; then
    [[ "${gh_latest}" == "${version}" ]] || printf '%s' "${version}"
    return 0
  fi
  [[ "${gh_latest}" == "${version}" ]] || return 0
  # the highest published release above this version that is itself latest
  while IFS= read -r t; do
    [[ -n "${t}" && "$(rf_semver_cmp "${t}" "${version}")" == "1" ]] || continue
    if [[ "$(bash "${RF_SCRIPTS}/publication/latest.sh" --project-dir "${RF_PROJECT_DIR}" --version "${t}")" == "true" ]]; then
      printf '%s' "${t}"
      return 0
    fi
  done <<< "$(rf_semver_tags "$(printf '%s' "${rels}" | jq -r '.[] | select(.draft == false) | "0 refs/tags/\(.tag_name)"')")"
}

# observe_json: prints the observation
observe_json() {
  local rels matches count rel actual name digest f want plan=""
  rels="$(list_releases)" || return 1
  matches="$(printf '%s' "${rels}" | jq -c --arg v "${version}" '[.[] | select(.tag_name == $v)]')"
  count="$(printf '%s' "${matches}" | jq 'length')"
  if [[ "${count}" == "0" ]]; then
    jq -nc '{state: "absent", detail: {}}'
    return 0
  fi
  if [[ "${count}" != "1" ]]; then
    jq -nc --argjson m "${matches}" '{state: "conflict", detail: {reason: "several releases for the tag", release_ids: [$m[].id]}}'
    return 0
  fi
  rel="$(printf '%s' "${matches}" | jq -c '.[0]')"
  actual="[]"
  while IFS=$'\t' read -r name digest; do
    [[ -n "${name}" ]] || continue
    if [[ "${digest}" != sha256:* ]]; then
      f="${WORK}/dl-$$-${RANDOM}"
      mkdir -p "${f}"
      gh release download "${version}" --repo "${repo}" --pattern "${name}" --dir "${f}" >/dev/null 2>&1 \
        || { echo "cannot download asset ${name} to check its digest" >&2; return 1; }
      digest="sha256:$(rf_sha256_file "${f}/${name}")"
      rm -rf "${f}"
    fi
    actual="$(jq -c --arg n "${name}" --arg d "${digest#sha256:}" '. + [{name: $n, sha256: $d}]' <<< "${actual}")"
  done <<< "$(printf '%s' "${rel}" | jq -r '.assets[]? | [.name, (.digest // "")] | @tsv')"
  want="$(desired_json)"
  if [[ "$(printf '%s' "${rel}" | jq -r .draft)" == "false" ]]; then
    plan="$(latest_plan "${rels}" "${RF_IS_LATEST:-false}")"
  fi
  jq -nc --argjson rel "${rel}" --argjson want "${want}" --argjson have "${actual}" --arg plan "${plan}" '
    ($want | map({(.name): .sha256}) | add // {}) as $w
    | ($have | map({(.name): .sha256}) | add // {}) as $h
    | ([$w | keys[] | select($h[.] == null)]) as $missing
    | ([$w | keys[] | select($h[.] != null and $h[.] != $w[.])]) as $wrong
    | ([$h | keys[] | select($w[.] == null)]) as $stray
    | {release_id: $rel.id, draft: $rel.draft, missing: $missing, wrong: $wrong, stray: $stray} as $d
    | if $rel.draft then {state: "partial", detail: $d}
      elif ($missing + $wrong + $stray | length) != 0 then {state: "conflict", detail: ($d + {reason: "published release assets differ from the manifest"})}
      elif $plan != "" then {state: "partial", detail: ($d + {latest_pending: $plan})}
      else {state: "complete", detail: $d} end'
}

write_notes() {
  local notes="$1" commit previous range changes
  commit="$(jq -r .candidate_commit "${RF_RELEASE_DIR}/release.json")"
  previous="$(git -C "${RF_PROJECT_DIR}" describe --tags --abbrev=0 --match '[0-9]*.[0-9]*.[0-9]*' "${commit}^" 2>/dev/null || true)"
  range="${commit}"
  [[ -z "${previous}" ]] || range="${previous}..${commit}"
  changes="$(git -C "${RF_PROJECT_DIR}" log --no-merges --format='- %s (%h)' "${range}" 2>/dev/null | head -n 200 || true)"
  {
    echo "## Changes"
    echo
    echo "${changes:-- Release ${version}}"
    if [[ -n "${previous}" ]]; then
      echo
      echo "**Full changelog**: https://github.com/${repo}/compare/${previous}...${version}"
    fi
    echo
    echo "## Verify"
    echo
    echo "Candidate commit \`${commit}\`, manifest.json sha256 \`$(jq -r .manifest_sha256 "${RF_RELEASE_DIR}/release.json")\`."
    echo
    echo '```sh'
    echo 'sha256sum --check SHA256SUMS'
    echo '```'
  } > "${notes}"
}

# latest_repair: GitHub's latest marker follows the newest promoted, published
# release (re-decided now: a newer release may have been promoted meanwhile).
latest_repair() {
  local now rels target
  now="$(bash "${RF_SCRIPTS}/publication/latest.sh" --project-dir "${RF_PROJECT_DIR}" --version "${version}")" || return 1
  rels="$(list_releases)" || return 1
  target="$(latest_plan "${rels}" "${now}")" || return 1
  [[ -n "${target}" ]] || return 0
  echo "github-release: marking ${target} as the latest GitHub release" >&2
  gh release edit "${target}" --repo "${repo}" --latest=true >&2
}

apply() {
  local obs state name
  obs="$(observe_json)" || return 1
  state="$(printf '%s' "${obs}" | jq -r .state)"
  case "${state}" in
    conflict)
      echo "github-release: refusing to modify: $(printf '%s' "${obs}" | jq -c .detail)" >&2
      return 5
      ;;
    complete)
      latest_repair || return 1
      return 0
      ;;
    absent)
      write_notes "${WORK}/notes.md"
      gh release create "${version}" --repo "${repo}" --draft --verify-tag --title "${version}" \
        --notes-file "${WORK}/notes.md" >&2 || return 1
      obs="$(observe_json)" || return 1
      ;;
  esac
  if [[ "$(printf '%s' "${obs}" | jq -r '.detail.draft')" == "false" ]]; then
    # published with exact assets; only the latest marker is pending
    latest_repair || return 1
    return 0
  fi
  [[ "$(printf '%s' "${obs}" | jq -r .state)" == "partial" ]] || { echo "github-release: expected a draft release for ${version}" >&2; return 1; }
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    gh release delete-asset "${version}" "${name}" --repo "${repo}" --yes >&2 || return 1
  done <<< "$(printf '%s' "${obs}" | jq -r '.detail.wrong[], .detail.stray[]')"
  while IFS= read -r name; do
    [[ -n "${name}" ]] || continue
    gh release upload "${version}" "${artifacts}/${name}" --repo "${repo}" >&2 || return 1
  done <<< "$(printf '%s' "${obs}" | jq -r '.detail.missing[], .detail.wrong[]')"
  obs="$(observe_json)" || return 1
  if ! printf '%s' "${obs}" | jq -e '.state == "partial" and .detail.draft and ((.detail.missing + .detail.wrong + .detail.stray) | length) == 0' >/dev/null; then
    echo "github-release: draft inventory still differs: $(printf '%s' "${obs}" | jq -c .detail)" >&2
    return 1
  fi
  gh release edit "${version}" --repo "${repo}" --draft=false --latest="${RF_IS_LATEST:-false}" >&2 || return 1
  latest_repair || return 1
}

case "${action}" in
  observe) observe_json ;;
  apply) apply ;;
  *) echo "Usage: github-release.sh observe|apply" >&2; exit 2 ;;
esac
