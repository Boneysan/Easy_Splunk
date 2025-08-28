#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# resolve-digests.sh — pin tags in versions.env to immutable digests
#
# What this does
#  - Reads image repo + version pairs from versions.env (e.g., FOO_IMAGE_REPO + FOO_VERSION)
#  - Pulls <repo>:<version> with the detected container runtime (docker or podman)
#  - Resolves the image’s immutable digest (sha256:…)
#  - Updates/creates:
#       <PREFIX>_IMAGE_DIGEST="sha256:…"
#       <PREFIX>_IMAGE="<repo>@sha256:…"
#  - Creates versions.env.bak and sed sidecar backups
#
# Requirements
#  - lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh (in ./lib)
#  - Docker or Podman available to pull/inspect images
#
# Notes
#  - Handles registries with ports (e.g., registry:5000/ns/app:tag)
#  - If pull/inspect fails for a particular image, that image is skipped (others still processed)
#  - Idempotent: safe to re-run; it’ll refresh DIGEST/IMAGE lines
#
# Version: 1.0.0
#


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# deps
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/run-with-log.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=lib/image-validator.sh
source "${SCRIPT_DIR}/lib/image-validator.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "resolve-digests.sh requires security.sh version >= 1.0.0"
fi

readonly VERSIONS_FILE="versions.env"
: "${SECRETS_DIR:=./secrets}"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Resolves tags in ${VERSIONS_FILE} to SHA256 digests and updates:
  • <PREFIX>_IMAGE_DIGEST
  • <PREFIX>_IMAGE  (to "<REPO>@<DIGEST>")
Creates backups: ${VERSIONS_FILE}.bak (full) and sed sidecars as needed.
EOF
}

# Portable in-place sed
_sed_inplace() {
  local script="$1" file="$2"
  if sed --version >/dev/null 2>&1; then
    sed -i.sibak -e "${script}" "${file}"
  else
    sed -i .sibak -e "${script}" "${file}"
  fi
}

# Split image reference
_split_repo_tag() {
  local ref="$1"
  if [[ "$ref" == *"@"* ]]; then
    printf '%s\n' "${ref%%@*}"
    printf '%s\n' ""
    return 0
  fi
  local after_slash="${ref##*/}"
  if [[ "$after_slash" == *":"* ]]; then
    printf '%s\n' "${ref%:*}"
    printf '%s\n' "${ref##*:}"
  else
    printf '%s\n' "${ref}"
    printf '%s\n' ""
  fi
}

# Resolve digest
_get_digest_for_image() {
  local image_ref="$1"
  if [[ "$image_ref" == *"@"* ]]; then
    printf '%s\n' "${image_ref##*@}"
    return 0
  fi
  local repo tag
  read -r repo tag < <(_split_repo_tag "${image_ref}")
  log_info "  -> Pulling ${image_ref} (to read manifest/digest)…"
  if [[ -f "${SECRETS_DIR}/registry_auth" ]]; then
    "${CONTAINER_RUNTIME}" login --username "$(curl_auth_get_username "${SECRETS_DIR}/registry_auth")" \
      --password "$(curl_auth_get_password "${SECRETS_DIR}/registry_auth")" "${repo}" >/dev/null 2>&1 || true
  fi
  if ! "${CONTAINER_RUNTIME}" pull "${image_ref}" &>/dev/null; then
    log_error "     pull failed for ${image_ref}"
    return 1
  fi
  local digests
  if ! digests="$("${CONTAINER_RUNTIME}" image inspect "${image_ref}" \
        --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null)"; then
    log_error "     inspect failed for ${image_ref}"
    return 1
  fi
  digests="$(printf '%s\n' "$digests" | sed '/^[[:space:]]*$/d')"
  if [[ -z "${digests}" ]]; then
    log_error "     no RepoDigests found for ${image_ref}"
    return 1
  fi
  local match
  match="$(printf '%s\n' "${digests}" | grep -E "^${repo}@" || true)"
  if [[ -z "${match}" ]]; then
    if [[ "${repo}" != */* ]]; then
      match="$(printf '%s\n' "${digests}" | grep -E "^(docker\.io/)?library/${repo}@" || true)"
    fi
  fi
  match="${match:-$(printf '%s\n' "${digests}" | head -n1)}"
  local digest="${match##*@}"
  if [[ -z "${digest}" ]]; then
    log_error "     could not determine digest for ${image_ref}"
    return 1
  fi
  printf '%s\n' "${digest}"
}

main() {
  if [[ $# -gt 0 ]]; then usage; exit 0; fi
  [[ -f "${VERSIONS_FILE}" ]] || die "${E_MISSING_DEP:-3}" "File not found: ${VERSIONS_FILE}"
  detect_container_runtime
  log_info "Using container runtime: ${CONTAINER_RUNTIME}"
  mkdir -p "${SECRETS_DIR}"
  harden_file_permissions "${SECRETS_DIR}" "700" "secrets directory" || true
  cp -f "${VERSIONS_FILE}" "${VERSIONS_FILE}.bak"
  harden_file_permissions "${VERSIONS_FILE}.bak" "600" "versions backup" || true
  log_info "Backup created: ${VERSIONS_FILE}.bak"
  # shellcheck disable=SC1090
  source "${VERSIONS_FILE}"
  mapfile -t PREFIXES < <(awk '
    /^[[:space:]]*readonly[[:space:]]+[A-Z_]+_IMAGE_REPO=/{ 
      match($0,/readonly[[:space:]]+([A-Z_]+)_IMAGE_REPO=/,m); 
      if(m[1]!="") print m[1];
    }' "${VERSIONS_FILE}" | sort -u)
  if ((${#PREFIXES[@]}==0)); then
    die "${E_INVALID_INPUT:-2}" "No *_IMAGE_REPO entries found in ${VERSIONS_FILE}"
  fi
  for prefix in "${PREFIXES[@]}"; do
    log_info "Processing: ${prefix}"
    local repo_var="${prefix}_IMAGE_REPO"
    local ver_var="${prefix}_VERSION"
    local dig_var="${prefix}_IMAGE_DIGEST"
    local img_var="${prefix}_IMAGE"
    local repo="${!repo_var-}"
    local ver="${!ver_var-}"
    if [[ -z "${repo:-}" || -z "${ver:-}" ]]; then
      log_warn "  -> Skipping ${prefix}: missing ${repo_var} or ${ver_var}"
      continue
    fi
    local ref="${repo}:${ver}"
    local digest
    if ! digest="$(_get_digest_for_image "${ref}")"; then
      log_warn "  -> Skipping ${prefix}: digest resolution failed for ${ref}"
      continue
    fi
    log_success "  -> ${ref} -> ${digest}"
    if grep -qE "^[[:space:]]*readonly[[:space:]]+${dig_var}=" "${VERSIONS_FILE}"; then
      _sed_inplace "s|^[[:space:]]*readonly[[:space:]]\\+${dig_var}=.*|readonly ${dig_var}=\"${digest}\"|" "${VERSIONS_FILE}"
    else
      _sed_inplace "/^[[:space:]]*readonly[[:space:]]\\+${ver_var}=.*/a\\
readonly ${dig_var}=\"${digest}\"
" "${VERSIONS_FILE}"
    fi
    local new_image="${repo}@${digest}"
    if grep -qE "^[[:space:]]*readonly[[:space:]]+${img_var}=" "${VERSIONS_FILE}"; then
      _sed_inplace "s|^[[:space:]]*readonly[[:space:]]\\+${img_var}=.*|readonly ${img_var}=\"${new_image}\"|" "${VERSIONS_FILE}"
    else
      _sed_inplace "/^[[:space:]]*readonly[[:space:]]\\+${dig_var}=.*/a\\
readonly ${img_var}=\"${new_image}\"
" "${VERSIONS_FILE}"
    fi
  done
  rm -f "${VERSIONS_FILE}.sibak" 2>/dev/null || true
  harden_file_permissions "${VERSIONS_FILE}" "600" "versions file" || true
  audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"
  
  # Validate supply chain security after digest resolution
  log_info "Validating supply chain security compliance..."
  if command -v validate_image_supply_chain >/dev/null 2>&1; then
    if validate_deployment_supply_chain; then
      log_success "✅ Supply chain security validation passed"
    else
      log_warning "⚠️  Supply chain security validation found issues"
      log_info "Run with DEPLOYMENT_MODE=production for stricter validation"
    fi
  else
    log_debug "Supply chain validation not available"
  fi
  
  log_success "✅ ${VERSIONS_FILE} updated with resolved digests and IMAGE pins."
  log_info "Review and commit changes."
}

RESOLVE_DIGESTS_VERSION="1.0.0"
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_entrypoint main "$@"
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "resolve-digests"

# Set error handling


