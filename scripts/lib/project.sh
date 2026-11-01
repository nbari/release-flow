# shellcheck shell=bash
# Static project validation. Never source or execute a consumer adapter.
# Requires common.sh and schema.sh from the trusted runtime.

# Resolve a relative path beneath a physical root. Reject symlinks at every
# component, including links that currently point back inside the root.
rf_project_path() {
  local root="$1" rel="$2" rest part path="$1"
  case "${rel}" in
    ''|/*|*/|*//*|*$'\n'*|*$'\r'*|*$'\t'*) rf_die "Unsafe project path: ${rel}" 3 ;;
  esac
  rest="${rel}"
  while [[ -n "${rest}" ]]; do
    part="${rest%%/*}"
    case "${part}" in .|..) rf_die "Unsafe project path component: ${rel}" 3 ;; esac
    path="${path}/${part}"
    [[ ! -L "${path}" ]] || rf_die "Symlink is not allowed in project path: ${rel}" 3
    if [[ "${rest}" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
  done
  case "${path}" in "${root}/"*) printf '%s' "${path}" ;; *) return 3 ;; esac
}

# Set RF_CONFIG_JSON and RF_ADAPTER (relative path). An explicit adapter must
# agree with the config, so local commands and CI cannot select different code.
rf_project_config() {
  local root="$1" requested="${2:-}" cfg adapter
  cfg="$(rf_project_path "${root}" .release-flow.json)"
  rf_schema_check config "${cfg}" || rf_die "Invalid .release-flow.json; correct the schema errors above" 3
  rf_config_load_text "$(cat "${cfg}")" || rf_die "Invalid configuration" 3
  RF_ADAPTER="$(rf_cfg .adapter)"
  [[ -z "${requested}" || "${requested}" == "${RF_ADAPTER}" ]] || rf_die "adapter input must match .release-flow.json adapter (${RF_ADAPTER})" 3
  adapter="$(rf_project_path "${root}" "${RF_ADAPTER}")"
  [[ -f "${adapter}" && -x "${adapter}" ]] || rf_die "Adapter must be an executable regular file: ${RF_ADAPTER} (commit chmod +x)" 3
}

# Static opt-in declaration of protocol v1. Running even `version` would
# execute arbitrary consumer code, so the Marketplace validator never does so.
rf_adapter_contract() {
  local adapter="$1" first interpreter
  IFS= read -r first < "${adapter}" || rf_die "Cannot read adapter shebang" 3
  case "${first}" in
    '#!/usr/bin/env '*)
      interpreter="${first#\#!/usr/bin/env }"
      [[ "${interpreter}" =~ ^[A-Za-z0-9._+-]+$ ]] || rf_die "Use a single interpreter in adapter shebang (for example #!/usr/bin/env bash)" 3
      rf_require_tools "${interpreter}"
      ;;
    '#!'/*)
      interpreter="${first#\#!}"
      [[ "${interpreter}" != *[[:space:]]* && -x "${interpreter}" ]] || rf_die "Adapter interpreter is unavailable or has unsupported options" 3
      ;;
    *) rf_die "Adapter requires an explicit interpreter shebang" 3 ;;
  esac
  grep -qxF '# release-flow-adapter: 1' "${adapter}" || rf_die "Adapter must declare '# release-flow-adapter: 1'; implement version, set-version, verify, targets, inventory and package (see docs/ADOPTION.md)" 3
  case "${interpreter##*/}" in
    bash) bash -n "${adapter}" || rf_die "Adapter shell syntax is invalid" 3 ;;
    sh) /bin/sh -n "${adapter}" || rf_die "Adapter shell syntax is invalid" 3 ;;
  esac
}
