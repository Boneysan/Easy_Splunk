#!/usr/bin/env bash
#
# ==============================================================================
# verify-bundle.sh — Comprehensive verifier for air-gapped bundles
# ==============================================================================
# What this does
#   • Verifies the outer bundle checksum (if <bundle>.sha256 is present)
#   • Unpacks to a temp dir (strip top-level dir)
#   • Validates required files/dirs exist
#   • Parses manifest.json (if present) and validates the inner images archive
#     (images.tar | images.tar.gz | images.tar.zst) + its .sha256 if present
#   • Optional docker/podman compose validation: `<compose> -f docker-compose.yml config`
#   • Script hygiene: +x on *.sh, shebang on first line, no CRLF endings
#   • Basic sensitive/unwanted file scan
#
# Exit codes
#   0 = PASS, non-zero = FAIL
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh
# Optional    : lib/runtime-detection.sh (for compose validation), jq, shellcheck
# Version: 1.0.0
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "verify-bundle.sh requires security.sh version >= 1.0.0"
fi

# --- Config / Defaults ---
readonly REQUIRED_FILES_BASE=(
  "airgapped-quickstart.sh"
  "docker-compose.yml"
  "manifest.json"
  "lib/core.sh"
  "lib/error-handling.sh"
  "lib/runtime-detection.sh"
  "lib/air-gapped.sh"
)

OVERALL_STATUS="GOOD"
DO_COMPOSE_VALIDATE="auto"
LIST_TREE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <path_to_bundle.tar.gz>

Options:
  --compose-validate auto|always|never   Validate docker-compose.yml (default: auto)
  --list                                 Show a compact tree of unpacked contents
  -h, --help                             Show this help

Examples:
  $(basename "$0") ./app-bundle-v3.5.1-20250101.tar.gz
  $(basename "$0") --compose-validate=always ./bundle.tgz
EOF
}

# --- Helpers ---
_have() { command -v "$1" >/dev/null 2>&1; }

_verify_checksum_file_pair() {
  local target="$1"
  local chk="${2:-${target}.sha256}"
  if [[ ! -f "${chk}" ]]; then
    log_warn "No checksum file for $(basename "${target}"); skipping checksum verification."
    return 0
  fi
  log_info "Verifying checksum: $(basename "${chk}")"
  local dir base
  dir="$(dirname "${target}")"
  base="$(basename "${target}")"
  pushd "${dir}" >/dev/null
  if _have sha256sum; then
    sha256sum -c "$(basename "${chk}")"
  else
    shasum -a 256 -c "$(basename "${chk}")"
  fi
  local rc=$?
  popd >/dev/null
  return "${rc}"
}

_find_images_archive() {
  local root="$1"
  local from_manifest=""
  if [[ -f "${root}/manifest.json" ]]; then
    if _have jq; then
      from_manifest="$(jq -r '.archive // empty' "${root}/manifest.json" 2>/dev/null || true)"
    else
      from_manifest="$(grep -oE '"archive"[[:space:]]*:[[:space:]]*"[^"]+"' "${root}/manifest.json" \
        | sed 's/.*"archive"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' | head -n1 || true)"
    fi
    if [[ -n "${from_manifest}" && -f "${root}/${from_manifest}" ]]; then
      printf '%s\n' "${root}/${from_manifest}"
      return 0
    fi
  fi
  local cand
  cand="$(ls -1 "${root}"/images.tar* 2>/dev/null | head -n1 || true)"
  [[ -n "${cand}" ]] && printf '%s\n' "${cand}"
}

_scan_scripts() {
  local root="$1"
  local non_exec
  non_exec="$(find "${root}" -type f -name "*.sh" ! -perm -u+x -print || true)"
  if [[ -n "${non_exec}" ]]; then
    log_warn "Some *.sh are not executable:"
    echo "${non_exec}"
    OVERALL_STATUS="BAD"
  else
    log_success "All *.sh files are executable."
  fi
  local bad_shebang=""
  while IFS= read -r -d '' f; do
    head -n1 "$f" | grep -qE '^#!' || bad_shebang+="$f"$'\n'
  done < <(find "${root}" -type f -name "*.sh" -print0)
  if [[ -n "${bad_shebang}" ]]; then
    log_warn "Some shell scripts lack a shebang on the first line:"
    printf '%s' "${bad_shebang}"
    OVERALL_STATUS="BAD"
  else
    log_success "Shebang check OK for *.sh."
  fi
  local bad_crlf
  bad_crlf="$(grep -RIl $'\r' "${root}" || true)"
  if [[ -n "${bad_crlf}" ]]; then
    log_warn "Files with CRLF line endings detected:"
    echo "${bad_crlf}"
    OVERALL_STATUS="BAD"
  else
    log_success "No CRLF line endings detected."
  fi
  if _have shellcheck; then
    log_info "Running shellcheck (best-effort) on *.sh ..."
    mapfile -t shfiles < <(find "${root}" -type f -name "*.sh" -print)
    ((${#shfiles[@]})) && shellcheck "${shfiles[@]}" || true
  fi
}

_sensitive_scan() {
  local root="$1"
  local findings
  findings="$(find "${root}" -type f \( \
      -iname "*.key" -o -iname "*.pem" -o -iname "id_rsa" -o -iname "*.pfx" -o -iname "*.p12" -o \
      -iname "*.bak" -o -iname "*.swo" -o -iname "*.swp" -o \
      -iname ".DS_Store" -o -iname "Thumbs.db" -o -name "*.env" -o -name ".netrc" \
    \) -print || true)"
  if [[ -n "${findings}" ]]; then
    log_error "Potentially sensitive/unwanted files found:"
    echo "${findings}"
    OVERALL_STATUS="BAD"
  else
    log_success "No sensitive/unwanted files found."
  fi
}

_compose_validate_if_possible() {
  local root="$1"
  local compose_file="${root}/docker-compose.yml"
  case "${DO_COMPOSE_VALIDATE}" in
    never) log_info "Compose validation disabled (never)."; return 0 ;;
  esac
  if [[ ! -f "${compose_file}" ]]; then
    log_error "Compose file missing — cannot validate."
    OVERALL_STATUS="BAD"
    return 0
  fi
  local compose_cmd=""
  if [[ -f "${root}/lib/runtime-detection.sh" ]]; then
    # shellcheck source=/dev/null
    source "${root}/lib/runtime-detection.sh"
    if detect_container_runtime &>/dev/null; then
      compose_cmd="${COMPOSE_COMMAND}"
    fi
  fi
  if [[ -z "${compose_cmd}" ]]; then
    if _have docker && docker compose version >/dev/null 2>&1; then
      compose_cmd="docker compose"
    elif _have docker-compose; then
      compose_cmd="docker-compose"
    elif _have podman && podman compose version >/dev/null 2>&1; then
      compose_cmd="podman compose"
    fi
  fi
  if [[ -z "${compose_cmd}" ]]; then
    case "${DO_COMPOSE_VALIDATE}" in
      always)
        log_error "Compose validation requested but no docker/podman compose available."
        OVERALL_STATUS="BAD"
        ;;
      auto)
        log_warn "No container runtime/compose available; skipping compose validation."
        ;;
    esac
    return 0
  fi
  read -r -a COMPOSE_COMMAND_ARRAY <<< "${compose_cmd}"
  log_info "Validating docker-compose.yml using: ${compose_cmd}"
  if ! "${COMPOSE_COMMAND_ARRAY[@]}" -f "${compose_file}" config >/dev/null; then
    log_error "docker-compose.yml failed to validate with '${compose_cmd} config'."
    OVERALL_STATUS="BAD"
  else
    log_success "Compose file validated."
  fi
}

_show_tree() {
  local root="$1"
  log_info "Bundle tree (depth 2):"
  if _have tree; then
    (cd "${root}" && tree -L 2 -a)
  else
    (cd "${root}" && find . -maxdepth 2 -print | sed 's|^\./||')
  fi
}

# --- Main ---
main() {
  if [[ $# -lt 1 ]]; then usage; exit 0; fi
  local bundle_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compose-validate=*) DO_COMPOSE_VALIDATE="${1#*=}"; shift ;;
      --compose-validate)   DO_COMPOSE_VALIDATE="${2:-auto}"; shift 2 ;;
      --list)               LIST_TREE=1; shift ;;
      -h|--help)            usage; exit 0 ;;
      *)                    bundle_file="$1"; shift ;;
    esac
  done
  [[ -n "${bundle_file}" && -f "${bundle_file}" ]] || die "${E_INVALID_INPUT:-2}" "Bundle file not found: ${bundle_file}"
  [[ "${DO_COMPOSE_VALIDATE}" =~ ^(auto|always|never)$ ]] || die "${E_INVALID_INPUT:-2}" "--compose-validate must be auto|always|never"
  log_info "🚀 Verifying bundle: ${bundle_file}"
  log_info "\n--- Step 1: Top-level checksum ---"
  if ! _verify_checksum_file_pair "${bundle_file}"; then
    die "${E_GENERAL:-1}" "Main bundle checksum verification FAILED."
  fi
  log_success "Top-level checksum OK (or not present)."
  log_info "\n--- Step 2: Unpack and structure checks ---"
  local staging_dir
  staging_dir="$(mktemp -d -t bundle-verify-XXXXXX)"
  add_cleanup_task "rm -rf '${staging_dir}'"
  harden_file_permissions "${staging_dir}" "700" "staging directory" || true
  log_debug "Staging at: ${staging_dir}"
  tar -xzf "${bundle_file}" -C "${staging_dir}" --strip-components=1
  audit_security_configuration "${staging_dir}/security-audit.txt"
  (( LIST_TREE == 1 )) && _show_tree "${staging_dir}"
  for f in "${REQUIRED_FILES_BASE[@]}"; do
    if [[ -e "${staging_dir}/${f}" ]]; then
      log_success "  ✔ Required: ${f}"
    else
      log_error   "  ✖ Missing : ${f}"
      OVERALL_STATUS="BAD"
    fi
  done
  log_info "\n--- Step 3: Manifest & inner images archive ---"
  local img_archive img_sha
  img_archive="$(_find_images_archive "${staging_dir}")"
  if [[ -z "${img_archive}" ]]; then
    log_error "Could not locate images archive (looked for manifest.archive or images.tar*)."
    OVERALL_STATUS="BAD"
  else
    log_success "Found images archive: $(basename "${img_archive}")"
    img_sha="${img_archive}.sha256"
    if [[ -f "${img_sha}" ]]; then
      if _verify_checksum_file_pair "${img_archive}" "${img_sha}"; then
        log_success "Inner images archive checksum OK."
      else
        log_error "Inner images archive checksum FAILED."
        OVERALL_STATUS="BAD"
      fi
    else
      log_warn "No checksum for inner images archive; skipping verification."
    fi
  fi
  log_info "\n--- Step 4: Script hygiene checks ---"
  _scan_scripts "${staging_dir}"
  log_info "\n--- Step 5: Sensitive file scan ---"
  _sensitive_scan "${staging_dir}"
  log_info "\n--- Step 6: Compose file validation ---"
  _compose_validate_if_possible "${staging_dir}"
  log_info "\n--- Verification Summary ---"
  if [[ "${OVERALL_STATUS}" == "GOOD" ]]; then
    log_success "✅ Bundle verification PASSED."
    exit 0
  else
    die "${E_GENERAL:-1}" "❌ Bundle verification FAILED. See details above."
  fi
}

VERIFY_BUNDLE_VERSION="1.0.0"
main "$@"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "verify-bundle"

# Set error handling
set -euo pipefail


