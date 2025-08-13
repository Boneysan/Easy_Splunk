#!/usr/bin/env bash
# ==============================================================================
# lib/versions.sh
# Helpers for validating version strings and image digests, and building refs.
#
# Dependencies: lib/core.sh (log_* and die), optional: lib/error-handling.sh
# ==============================================================================

# Guard for core
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/versions.sh" >&2
  exit 1
fi

# validate_version_format "1.2.3"
validate_version_format() {
  local v="${1-}"
  [[ "${v}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# is_valid_digest "sha256:...."
is_valid_digest() {
  local d="${1-}"
  [[ "${d}" =~ ^sha256:[a-f0-9]{64}$ ]]
}

# image_ref <repo> <digest> [tag]
# Returns repo@digest if digest valid, otherwise repo:tag (warns if tag used).
image_ref() {
  local repo="${1:?repo required}"
  local digest="${2-}"
  local tag="${3-}"

  if [[ -n "${digest}" ]] && is_valid_digest "${digest}"; then
    printf '%s@%s\n' "${repo}" "${digest}"
    return 0
  fi
  if [[ -n "${tag}" ]]; then
    log_warn "Using mutable tag for ${repo}: ${tag} (no valid digest provided)"
    printf '%s:%s\n' "${repo}" "${tag}"
    return 0
  fi
  die "${E_INVALID_INPUT}" "image_ref: need a valid digest or a tag for ${repo}"
}

# verify_versions_env — sanity-checks common *_VERSION and *_DIGEST vars.
# Call after sourcing versions.env.
verify_versions_env() {
  local ok=0
  local k

  # Check all *_DIGEST variables
  while IFS='=' read -r k _; do
    if [[ "${k}" == *_DIGEST ]]; then
      local v="${!k-}"
      if [[ -z "${v}" ]] || ! is_valid_digest "${v}"; then
        log_error "Bad digest in versions.env: ${k}='${v}'"
        ok=1
      fi
    fi
  done < <(env | LC_ALL=C sort)

  # Spot-check *_VERSION format (only those that look like semver)
  for k in $(env | awk -F= '/_VERSION=/{print $1}'); do
    local v="${!k-}"
    if [[ "${v}" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      # Strip optional leading v
      v="${v#v}"
      validate_version_format "${v}" || { log_error "Invalid semver: ${k}='${v}'"; ok=1; }
    fi
  done

  return "${ok}"
}

# load_versions_file [path]
# Sources versions.env (or specified file) and validates it.
load_versions_file() {
  local versions_file="${1:-versions.env}"
  
  if [[ ! -f "${versions_file}" ]]; then
    die "${E_INVALID_INPUT}" "Versions file not found: ${versions_file}"
  fi
  
  # Validate syntax in subshell first
  if ! (set -e; . "${versions_file}") >/dev/null 2>&1; then
    die "${E_INVALID_INPUT}" "Invalid syntax in versions file: ${versions_file}"
  fi
  
  # Source it for real
  . "${versions_file}"
  
  # Validate schema if present
  if [[ -n "${VERSION_FILE_SCHEMA:-}" ]]; then
    log_debug "Loaded versions from ${versions_file} (schema ${VERSION_FILE_SCHEMA})"
  else
    log_debug "Loaded versions from ${versions_file} (no schema version)"
  fi
  
  # Validate all loaded versions
  if ! verify_versions_env; then
    die "${E_INVALID_INPUT}" "Version validation failed for ${versions_file}"
  fi
  
  log_success "Versions loaded and validated: ${versions_file}"
}

# get_image_repo <image_ref>
# Extracts repository from repo@digest or repo:tag format
get_image_repo() {
  local image="${1:?image required}"
  echo "${image}" | cut -d@ -f1 | cut -d: -f1
}

# get_image_digest <image_ref>
# Extracts digest from repo@digest format (empty if tag format)
get_image_digest() {
  local image="${1:?image required}"
  if [[ "${image}" == *@* ]]; then
    echo "${image}" | cut -d@ -f2
  fi
}

# get_image_tag <image_ref>
# Extracts tag from repo:tag format (empty if digest format)
get_image_tag() {
  local image="${1:?image required}"
  if [[ "${image}" == *:* && "${image}" != *@* ]]; then
    echo "${image}" | cut -d: -f2
  fi
}

# list_all_images
# Lists all *_IMAGE variables currently defined
list_all_images() {
  env | grep '_IMAGE=' | cut -d= -f1 | sort
}

# list_all_versions
# Lists all *_VERSION variables currently defined
list_all_versions() {
  env | grep '_VERSION=' | cut -d= -f1 | sort
}