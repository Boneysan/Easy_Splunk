#!/usr/bin/env bash
#
# ==============================================================================
# verify-bundle.sh — Comprehensive verifier for air-gapped bundles
# ==============================================================================
# Checks:
#   • Verify outer bundle checksum (if .sha256 is present) OR validate via
#     provided checksum contents when available
#   • Unpack to a temp dir (strip top-level dir) and verify required files/dirs
#   • Verify inner images archive checksum if images.tar.sha256 exists
#   • Compose sanity: optionally run `<compose> -f docker-compose.yml config`
#     if a container runtime is available (non-fatal if absent)
#   • Script hygiene: executable bit, shebang present, no CRLF endings
#   • Basic sensitive-file scan
#
# Exit codes:
#   0 = PASS, non-zero = FAIL (with logs)
#
# Dependencies: lib/core.sh, lib/error-handling.sh
# Optional: lib/runtime-detection.sh (only for compose validation)
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"

# ---- Config -------------------------------------------------------------------
# Required items expected *inside* the unpacked bundle root:
readonly REQUIRED_FILES=(
  "images.tar"
  "airgapped-quickstart.sh"
  "docker-compose.yml"
  "lib/core.sh"
  "lib/error-handling.sh"
  "lib/runtime-detection.sh"
  "lib/air-gapped.sh"
)

OVERALL_STATUS="GOOD"
DO_COMPOSE_VALIDATE="auto"  # auto|always|never

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <path_to_bundle.tar.gz>

Options:
  --compose-validate auto|always|never   Validate docker-compose.yml via runtime (default: auto)
  -h, --help                             Show this help

Examples:
  $(basename "$0") ./app-bundle-v3.5.1-20250101.tar.gz
  $(basename "$0") --compose-validate=always ./bundle.tgz
EOF
}

# ---- Small helpers ------------------------------------------------------------
_have() { command -v "$1" >/dev/null 2>&1; }

_verify_checksum_file_pair() {
  # Args: <file> [<checksum_file>]
  local target="$1"
  local chk="${2:-${target}.sha256}"
  if [[ ! -f "${chk}" ]]; then
    log_warn "No checksum file found for $(basename "${target}"), skipping checksum verification."
    return 0
  fi
  log_info "Verifying checksum: $(basename "${chk}")"
  local dir base
  dir="$(dirname "${target}")"
  base="$(basename "${target}")"
  pushd "${dir}" >/dev/null
  if _have sha256sum; then
    if ! sha256sum -c "$(basename "${chk}")"; then popd >/dev/null; return 1; fi
  else
    if ! shasum -a 256 -c "$(basename "${chk}")"; then popd >/dev/null; return 1; fi
  fi
  popd >/dev/null
  return 0
}

_scan_scripts() {
  local root="$1"
  local bad_exec bad_shebang bad_crlf
  bad_exec="$(find "${root}" -type f -name "*.sh" -not -perm -u+x -print || true)"
  if [[ -n "${bad_exec}" ]]; then
    log_warn "Some *.sh are not executable:"
    echo "${bad_exec}"
  else
    log_success "All *.sh files are executable."
  fi

  bad_shebang="$(grep -RIl --exclude-dir .git -nE '^\s*#' "${root}" | xargs -r head -n 1 | grep -vE '^#!' || true)"
  if [[ -n "${bad_shebang}" ]]; then
    log_warn "Some shell-like files appear to lack a shebang on line 1 (review manually)."
  else
    log_success "Shebang check OK."
  fi

  bad_crlf="$(grep -RIl $'\r' "${root}" || true)"
  if [[ -n "${bad_crlf}" ]]; then
    log_warn "Files with CRLF line endings detected (Windows newlines):"
    echo "${bad_crlf}"
  else
    log_success "No CRLF line endings detected."
  fi

  if _have shellcheck; then
    log_info "Running shellcheck (best-effort) over *.sh ..."
    # Don’t fail the run; just surface warnings.
    mapfile -t shfiles < <(find "${root}" -type f -name "*.sh" -print)
    if ((${#shfiles[@]} > 0)); then
      shellcheck "${shfiles[@]}" || log_warn "shellcheck reported issues (see above)."
    fi
  fi
}

_sensitive_scan() {
  local root="$1"
  local findings
  findings="$(find "${root}" -type f \( \
      -iname "*.key" -o -iname "*.pem" -o -name "id_rsa" -o \
      -iname "*.bak" -o -iname "*.swo" -o -iname "*.swp" -o \
      -iname ".DS_Store" -o -iname "Thumbs.db" \
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
    log_warn "Compose file missing — cannot validate."
    OVERALL_STATUS="BAD"
    return 0
  fi

  # Try to source runtime detection and run '<compose> config'
  if [[ -f "${SCRIPT_DIR}/lib/runtime-detection.sh" ]]; then
    source "${SCRIPT_DIR}/lib/runtime-detection.sh"
  else
    log_warn "runtime-detection.sh not found beside verifier; skipping compose validation."
    return 0
  fi

  if ! detect_container_runtime &>/dev/null; then
    case "${DO_COMPOSE_VALIDATE}" in
      always)
        log_error "Compose validation requested but no runtime available."
        OVERALL_STATUS="BAD"
        ;;
      auto)
        log_warn "No container runtime available; skipping compose validation."
        ;;
    esac
    return 0
  fi

  read -r -a COMPOSE_COMMAND_ARRAY <<< "${COMPOSE_COMMAND}"
  log_info "Validating docker-compose.yml using: ${COMPOSE_COMMAND}"
  if ! "${COMPOSE_COMMAND_ARRAY[@]}" -f "${compose_file}" config >/dev/null; then
    log_error "docker-compose.yml failed to validate with '${COMPOSE_COMMAND} config'"
    OVERALL_STATUS="BAD"
  else
    log_success "Compose file validated."
  fi
}

# ---- Main ---------------------------------------------------------------------
main() {
  # Args
  if [[ $# -lt 1 ]]; then usage; exit 0; fi
  local bundle_file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --compose-validate=*) DO_COMPOSE_VALIDATE="${1#*=}"; shift ;;
      --compose-validate) DO_COMPOSE_VALIDATE="${2:-auto}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) bundle_file="$1"; shift ;;
    esac
  done

  [[ -n "${bundle_file}" && -f "${bundle_file}" ]] || die "${E_INVALID_INPUT:-2}" "Bundle file not found: ${bundle_file}"
  if [[ ! "${DO_COMPOSE_VALIDATE}" =~ ^(auto|always|never)$ ]]; then
    die "${E_INVALID_INPUT:-2}" "--compose-validate must be auto|always|never"
  fi

  log_info "🚀 Verifying bundle: ${bundle_file}"

  # Step 1: Verify outer checksum (if present)
  log_info "\n--- Step 1: Top-level checksum ---"
  if ! _verify_checksum_file_pair "${bundle_file}"; then
    die "${E_GENERAL:-1}" "Main bundle checksum verification FAILED."
  fi
  log_success "Top-level checksum OK (or not present)."

  # Step 2: Unpack bundle (strip top-level dir)
  log_info "\n--- Step 2: Unpack and structure checks ---"
  local staging_dir
  staging_dir="$(mktemp -d -t bundle-verify-XXXXXX)"
  add_cleanup_task "rm -rf '${staging_dir}'"
  log_debug "Staging at: ${staging_dir}"

  tar -xzf "${bundle_file}" -C "${staging_dir}" --strip-components=1

  # Step 3: Required files present?
  for f in "${REQUIRED_FILES[@]}"; do
    if [[ -e "${staging_dir}/${f}" ]]; then
      log_success "  ✔ Required: ${f}"
    else
      log_error   "  ✖ Missing:  ${f}"
      OVERALL_STATUS="BAD"
    fi
  done

  # Step 4: Verify inner images.tar checksum if exists
  log_info "\n--- Step 3: Inner images archive integrity ---"
  if [[ -f "${staging_dir}/images.tar" ]]; then
    if ! _verify_checksum_file_pair "${staging_dir}/images.tar" "${staging_dir}/images.tar.sha256"; then
      log_error "images.tar checksum FAILED."
      OVERALL_STATUS="BAD"
    else
      log_success "images.tar checksum OK (or not present)."
    fi
  fi

  # Step 5: Script hygiene
  log_info "\n--- Step 4: Script hygiene checks ---"
  _scan_scripts "${staging_dir}"

  # Step 6: Sensitive/unwanted file scan
  log_info "\n--- Step 5: Sensitive file scan ---"
  _sensitive_scan "${staging_dir}"

  # Step 7: Compose validation (optional)
  log_info "\n--- Step 6: Compose file validation ---"
  _compose_validate_if_possible "${staging_dir}"

  # Final summary
  log_info "\n--- Verification Summary ---"
  if [[ "${OVERALL_STATUS}" == "GOOD" ]]; then
    log_success "✅ Bundle verification PASSED."
    exit 0
  else
    die "${E_GENERAL:-1}" "❌ Bundle verification FAILED. See issues above."
  fi
}

main "$@"
