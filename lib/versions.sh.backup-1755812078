#!/usr/bin/env bash
# ==============================================================================
# lib/versions.sh
# Helpers for validating version strings and image digests, and building refs.
#
# Dependencies: lib/core.sh (expects: log_*, die, E_*, have_cmd)
# Optional:     lib/error-handling.sh (for register_cleanup, etc.)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh must be sourced before lib/versions.sh" >&2
  exit 1
fi

# ---- Built-in validation patterns (bash regex) --------------------------------
# Keep these internal (do not rely on versions.env regexes which may contain escaped literals)
# Semver: 1.2.3, optional leading v
__REGEX_SEMVER='^v?[0-9]+(\.[0-9]+){2}([.-][A-Za-z0-9.-]+)?(\+[A-Za-z0-9.-]+)?$'
__REGEX_DIGEST_SHA256='^sha256:[a-f0-9]{64}$'
# Very permissive repo pattern: registry[:port]/path/name (lowercase recommended but allow caps)
__REGEX_REPO='^[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._-]+)+$'

# ------------------------------------------------------------------------------
# Validation helpers
# ------------------------------------------------------------------------------

# validate_version_format "1.2.3" (accepts optional leading 'v')
validate_version_format() {
  local v="${1-}"
  [[ -n "$v" ]] && [[ "$v" =~ $__REGEX_SEMVER ]]
}

# is_valid_digest "sha256:...."
is_valid_digest() {
  local d="${1-}"
  [[ -n "$d" ]] && [[ "$d" =~ $__REGEX_DIGEST_SHA256 ]]
}

# is_valid_repo "registry:5000/ns/name" or "ns/name"
is_valid_repo() {
  local r="${1-}"
  [[ -n "$r" ]] && [[ "$r" =~ $__REGEX_REPO ]]
}

# ------------------------------------------------------------------------------
# Image reference builders / parsers
# ------------------------------------------------------------------------------

# image_ref <repo> <digest> [tag]
# Returns repo@digest if digest valid, otherwise repo:tag (warns if tag used).
image_ref() {
  local repo="${1:?repo required}"
  local digest="${2-}"
  local tag="${3-}"

  if [[ -n "$digest" ]] && is_valid_digest "$digest"; then
    printf '%s@%s\n' "$repo" "$digest"
    return 0
  fi
  if [[ -n "$tag" ]]; then
    log_warn "Using mutable tag for ${repo}: ${tag} (no valid digest provided)"
    printf '%s:%s\n' "$repo" "$tag"
    return 0
  fi
  die "${E_INVALID_INPUT}" "image_ref: need a valid digest or a tag for ${repo}"
}

# Robust parsers that handle registry ports. Docker tag delimiter is the last
# colon (:) AFTER the last slash. Digest delimiter is @.
# get_image_repo <image_ref>   -> full repo path without tag/digest
get_image_repo() {
  local image="${1:?image required}"
  local ref="${image%%@*}"            # strip digest part if present
  # If the last path segment contains a colon, it's a tag; strip it.
  local last_seg="${ref##*/}"
  if [[ "$last_seg" == *:* ]]; then
    printf '%s\n' "${ref%:*}"
  else
    printf '%s\n' "$ref"
  fi
}

# get_image_digest <image_ref> -> digest (empty if tag form)
get_image_digest() {
  local image="${1:?image required}"
  [[ "$image" == *@* ]] && printf '%s\n' "${image##*@}" || true
}

# get_image_tag <image_ref>    -> tag (empty if digest form)
get_image_tag() {
  local image="${1:?image required}"
  [[ "$image" == *@* ]] && return 0  # digest form -> no tag
  local name="${image##*/}"
  if [[ "$name" == *:* ]]; then
    printf '%s\n' "${name##*:}"
  fi
}

# ------------------------------------------------------------------------------
# versions.env loading + verification
# ------------------------------------------------------------------------------

# verify_versions_env — sanity-checks common *_VERSION and *_DIGEST vars.
# Call after sourcing versions.env.
verify_versions_env() {
  local ok=0

  # Check *_DIGEST variables present in current shell (not the entire process env)
  local var
  for var in $(compgen -A variable | LC_ALL=C grep -E '_DIGEST$' | LC_ALL=C sort); do
    # shellcheck disable=SC2154
    local val="${!var-}"
    if [[ -z "$val" ]] || ! is_valid_digest "$val"; then
      log_error "Bad digest in versions.env: ${var}='${val}'"
      ok=1
    fi
  done

  # Spot-check *_VERSION (only those that look like semver with optional leading v)
  for var in $(compgen -A variable | LC_ALL=C grep -E '_VERSION$' | LC_ALL=C sort); do
    local val="${!var-}"
    if [[ "$val" =~ ^v?[0-9]+(\.[0-9]+){2} ]]; then
      validate_version_format "$val" || { log_error "Invalid semver: ${var}='${val}'"; ok=1; }
    fi
  done

  # Basic *_IMAGE_REPO sanity (optional)
  for var in $(compgen -A variable | LC_ALL=C grep -E '_IMAGE_REPO$' | LC_ALL=C sort); do
    local val="${!var-}"
    if [[ -n "$val" ]] && ! is_valid_repo "$val"; then
      log_warn "Suspicious image repo format: ${var}='${val}'"
    fi
  done

  return "$ok"
}

# load_versions_file [path]
# Sources versions.env (or specified file) and validates it.
load_versions_file() {
  local versions_file="${1:-versions.env}"

  [[ -f "$versions_file" ]] || die "${E_INVALID_INPUT}" "Versions file not found: ${versions_file}"

  # Validate syntax in a subshell first (prevents partial pollution)
  if ! ( set -e; . "$versions_file" ) >/dev/null 2>&1; then
    die "${E_INVALID_INPUT}" "Invalid syntax in versions file: ${versions_file}"
  fi

  # Source for real
  . "$versions_file"

  if [[ -n "${VERSION_FILE_SCHEMA:-}" ]]; then
    log_debug "Loaded versions from ${versions_file} (schema ${VERSION_FILE_SCHEMA})"
  else
    log_debug "Loaded versions from ${versions_file} (no schema version)"
  fi

  if ! verify_versions_env; then
    die "${E_INVALID_INPUT}" "Version validation failed for ${versions_file}"
  fi

  log_success "Versions loaded and validated: ${versions_file}"
}

# ------------------------------------------------------------------------------
# Discovery helpers (current shell scope only)
# ------------------------------------------------------------------------------

# list_all_images — names of *_IMAGE variables (sorted)
list_all_images() {
  compgen -A variable | LC_ALL=C grep -E '_IMAGE$' | LC_ALL=C sort
}

# list_all_versions — names of *_VERSION variables (sorted)
list_all_versions() {
  compgen -A variable | LC_ALL=C grep -E '_VERSION$' | LC_ALL=C sort
}

# list_image_refs — print "VARNAME=VALUE" for *_IMAGE (sorted)
list_image_refs() {
  local v
  for v in $(list_all_images); do
    printf '%s=%s\n' "$v" "${!v-}"
  done
}

# list_version_values — print "VARNAME=VALUE" for *_VERSION (sorted)
list_version_values() {
  local v
  for v in $(list_all_versions); do
    printf '%s=%s\n' "$v" "${!v-}"
  done
}

# ------------------------------------------------------------------------------
# End of lib/versions.sh
# ------------------------------------------------------------------------------
