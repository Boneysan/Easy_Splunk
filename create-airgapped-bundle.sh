```bash
#!/usr/bin/env bash
# ==============================================================================
# create-airgapped-bundle.sh
# Build a comprehensive air-gapped bundle (images + scripts + configs).
#
# Produces:
#   - <OUT_DIR>/images.tar[.gz|.zst] (+ .sha256)  (container images archive)
#   - <OUT_DIR>/manifest.json           (metadata about the images archive)
#   - <OUT_DIR>/versions.env            (snapshot)
#   - <OUT_DIR>/...                     (your scripts/configs)
#   - ./<ARCHIVE_NAME>.tar.gz (+ .sha256) (final distributable)
#
# Flags:
#   --out <dir>           Output directory (default: dist/bundle-YYYYmmdd)
#   --name <name>         Final archive base name (default: app-bundle-v<BUNDLE_VERSION>-YYYYmmdd)
#   --compression <c>     Image tar compression: gzip|zstd|none (default: gzip)
#   --image <ref>         Add extra image (may be repeated)
#   --include <path>      Add extra file/dir into bundle (may be repeated)
#   --with-secrets        Generate secrets using generate-credentials.sh
#   --yes, -y             Non-interactive (assume yes)
#   -h, --help            Show usage
#
# Dependencies:
#   lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#   lib/runtime-detection.sh, lib/security.sh, lib/air-gapped.sh, generate-credentials.sh
# Version: 1.0.0
# ==============================================================================

set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source dependencies (order matters) ---------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/air-gapped.sh
source "${SCRIPT_DIR}/lib/air-gapped.sh"

# --- Version Checks ------------------------------------------------------------
if [[ "${AIR_GAPPED_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "create-airgapped-bundle.sh requires air-gapped.sh version >= 1.0.0"
fi
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "create-airgapped-bundle.sh requires security.sh version >= 1.0.0"
fi
verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# --- Defaults / flags -----------------------------------------------------------
OUT_DIR="dist/bundle-$(date +%Y%m%d)"
_BVER="${BUNDLE_VERSION:-${APP_VERSION:-0.0.0}}"
ARCHIVE_NAME="app-bundle-v${_BVER}-$(date +%Y%m%d)"
COMPRESSION="${TARBALL_COMPRESSION:-gzip}" # gzip|zstd|none
export TARBALL_COMPRESSION="${COMPRESSION}"
AUTO_YES=0
WITH_SECRETS=0
declare -a EXTRA_IMAGES=()
declare -a EXTRA_INCLUDES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --out <dir>            Output bundle directory (default: ${OUT_DIR})
  --name <name>          Final archive base name (default: ${ARCHIVE_NAME})
  --compression <c>      Image archive compression: gzip|zstd|none (default: ${COMPRESSION})
  --image <ref>          Add an extra container image (can repeat)
  --include <path>       Include extra file/dir in bundle (can repeat)
  --with-secrets         Generate secrets using generate-credentials.sh
  --yes, -y              Non-interactive (assume yes)
  -h, --help             Show this help and exit

Examples:
  $(basename "$0") --out dist/bundle-\$(date +%Y%m%d) --compression zstd
  $(basename "$0") --image alpine:3.20 --include docs/ --with-secrets
EOF
}

# --- CLI parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --name) ARCHIVE_NAME="${2:?}"; shift 2 ;;
    --compression) COMPRESSION="${2:?}"; export TARBALL_COMPRESSION="${COMPRESSION}"; shift 2 ;;
    --image) EXTRA_IMAGES+=("${2:?}"); shift 2 ;;
    --include) EXTRA_INCLUDES+=("${2:?}"); shift 2 ;;
    --with-secrets) WITH_SECRETS=1; shift ;;
    -y|--yes) AUTO_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1" ;;
  esac
done

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0 ;;
      [nN]|[nN][oO]|"")  die 0 "Cancelled by user." ;;
      *) log_warn "Please answer 'y' or 'n'." ;;
    esac
  done
}

# --- Collect images from versions.env (+extras), dedupe -------------------------
gather_images() {
  local -a imgs=()
  while IFS= read -r var; do
    local v="${!var:-}"
    [[ -n "${v}" ]] && imgs+=("${v}")
  done < <(list_all_images)
  imgs+=("${EXTRA_IMAGES[@]}")
  declare -A seen=()
  local -a out=()
  local i
  for i in "${imgs[@]}"; do
    [[ -z "${i}" ]] && continue
    if [[ -z "${seen[$i]:-}" ]]; then
      seen["$i"]=1
      out+=("$i")
    fi
  done
  printf '%s\n' "${out[@]}"
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "🚀 Creating air-gapped bundle"
  log_info "Output dir: ${OUT_DIR}"
  log_info "Archive name (final distributable): ${ARCHIVE_NAME}.tar.gz"
  log_info "Image archive compression (inside bundle): ${COMPRESSION}"
  if (( WITH_SECRETS == 1 )); then
    log_info "Secrets will be generated using generate-credentials.sh"
  fi

  # Build image list
  mapfile -t IMAGES < <(gather_images)
  (( ${#IMAGES[@]} > 0 )) || die "${E_INVALID_INPUT}" "No images found. Check versions.env or add --image."

  log_info "Images to include (${#IMAGES[@]}):"
  for i in "${IMAGES[@]}"; do log_info "  - ${i}"; done

  if [[ -e "${OUT_DIR}" ]]; then
    log_warn "Output directory already exists: ${OUT_DIR}"
    confirm_or_exit "Continue and reuse directory?"
  fi

  mkdir -p "${OUT_DIR}"
  register_cleanup "rm -rf '${OUT_DIR}'"

  # 1) Ensure runtime is ready and summarized
  detect_container_runtime
  runtime_summary

  # 2) Generate secrets if requested
  if (( WITH_SECRETS == 1 )); then
    log_info "Generating secrets for bundle..."
    "${SCRIPT_DIR}/generate-credentials.sh" --yes \
      --secrets-dir "${OUT_DIR}/config/secrets" \
      --certs-dir "${OUT_DIR}/config/certs" \
      --with-splunk
  fi

  # 3) Build the images bundle inside OUT_DIR
  create_airgapped_bundle "${OUT_DIR}" "${IMAGES[@]}"

  # 4) Add scripts/configs to the bundle directory
  log_info "Adding scripts and configs to bundle directory..."
  declare -a DEFAULT_INCLUDES=( "airgapped-quickstart.sh" "docker-compose.yml" "versions.env" "lib" "config" )
  DEFAULT_INCLUDES+=("${EXTRA_INCLUDES[@]}")
  for path in "${DEFAULT_INCLUDES[@]}"; do
    local src="${SCRIPT_DIR}/${path}"
    if [[ ! -e "${src}" ]]; then
      log_warn "Skip missing path: ${path}"
      continue
    fi
    if [[ "${path}" =~ secrets|credentials ]]; then
      cp -a "${src}" "${OUT_DIR}/"
      harden_file_permissions "${OUT_DIR}/${path}" "600" "sensitive file" || true
    else
      cp -a "${src}" "${OUT_DIR}/"
    fi
    log_debug "  -> Included: ${path}"
  done

  # 5) Create the final distributable tarball
  local parent dirbase archive archive_path
  parent="$(dirname -- "${OUT_DIR}")"
  dirbase="$(basename -- "${OUT_DIR}")"
  archive="${ARCHIVE_NAME}.tar.gz"
  archive_path="${PWD}/${archive}"

  if [[ -f "${archive}" ]]; then
    log_warn "Archive already exists: ${archive}"
    confirm_or_exit "Overwrite existing archive?"
    rm -f "${archive}" "${archive}.sha256"
  fi

  log_info "Packing final bundle archive: ${archive}"
  if tar --help 2>/dev/null | grep -q -- '--owner'; then
    tar --owner=0 --group=0 -czf "${archive_path}" -C "${parent}" "${dirbase}"
  else
    tar -czf "${archive_path}" -C "${parent}" "${dirbase}"
  fi

  # 6) Checksum for final archive
  generate_checksum_file "${archive}"

  # 7) Run security audit
  audit_security_configuration "${OUT_DIR}/security-audit.txt"

  # 8) Success: keep OUT_DIR
  unregister_cleanup "rm -rf '${OUT_DIR}'"

  log_success "✅ Air-gapped bundle created."
  log_info "Bundle dir: ${OUT_DIR}"
  log_info "Archive:    ${archive}"
  log_info "Checksum:   ${archive}.sha256"
  log_info "Transfer BOTH files to the target machine."
}

main "$@"
```