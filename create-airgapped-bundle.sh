#!/usr/bin/env bash
# ==============================================================================
# create-airgapped-bundle.sh
# Build a comprehensive bundle for offline installs (images + scripts + configs)
#
# Flags:
#   --out <dir>          Output directory (default: dist/bundle-YYYYmmdd)
#   --name <name>        Final archive name without extension (default: app-bundle-v<APP_VERSION>-YYYYmmdd)
#   --compression <c>    Image tar compression: gzip|zstd|none (default: gzip)
#   --image <ref>        Add an extra image (can be repeated)
#   --include <path>     Add extra file/dir into bundle (can be repeated)
#   --yes, -y            Non-interactive (assume yes)
#   -h, --help           Show usage
#
# Dependencies: lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#               lib/runtime-detection.sh, lib/air-gapped.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source dependencies (order matters) ---------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/air-gapped.sh
source "${SCRIPT_DIR}/lib/air-gapped.sh"

verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# --- Defaults / flags -----------------------------------------------------------
OUT_DIR="dist/bundle-$(date +%Y%m%d)"
ARCHIVE_NAME="app-bundle-v${APP_VERSION}-$(date +%Y%m%d)"
COMPRESSION="${TARBALL_COMPRESSION:-gzip}"   # propagate to lib/air-gapped
AUTO_YES=0
declare -a EXTRA_IMAGES=()
declare -a EXTRA_INCLUDES=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --out <dir>            Output bundle directory (default: ${OUT_DIR})
  --name <name>          Final archive name (no extension) (default: ${ARCHIVE_NAME})
  --compression <c>      Image tar compression: gzip|zstd|none (default: ${COMPRESSION})
  --image <ref>          Add an extra image (can repeat)
  --include <path>       Include extra file/dir in bundle (can repeat)
  --yes, -y              Non-interactive (assume yes to prompts)
  -h, --help             Show this help and exit

Examples:
  $(basename "$0") --out dist/bundle-\$(date +%Y%m%d) --compression zstd
  $(basename "$0") --image alpine:3.20 --include docs/
EOF
}

# --- CLI parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="${2:?}"; shift 2;;
    --name) ARCHIVE_NAME="${2:?}"; shift 2;;
    --compression) COMPRESSION="${2:?}"; shift 2;;
    --image) EXTRA_IMAGES+=("${2:?}"); shift 2;;
    --include) EXTRA_INCLUDES+=("${2:?}"); shift 2;;
    -y|--yes) AUTO_YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1";;
  esac
done

# Propagate compression selection to air-gapped lib
export TARBALL_COMPRESSION="${COMPRESSION}"

confirm_or_exit() {
  local prompt="${1:-Proceed?}"
  if (( AUTO_YES == 1 )); then return 0; fi
  while true; do
    read -r -p "${prompt} [y/N] " resp </dev/tty || resp=""
    case "${resp}" in
      [yY]|[yY][eE][sS]) return 0;;
      [nN]|[nN][oO]|"")  die 0 "Cancelled by user.";;
      *) log_warn "Please answer 'y' or 'n'.";;
    esac
  done
}

# --- Image list from versions.env (+ extras) ------------------------------------
declare -a IMAGES=()
append_if_set() { local v="${1-}"; [[ -n "${v}" ]] && IMAGES+=("${v}"); }
append_if_set "${APP_IMAGE:-}"
append_if_set "${REDIS_IMAGE:-}"
append_if_set "${PROMETHEUS_IMAGE:-}"
append_if_set "${GRAFANA_IMAGE:-}"
# Allow extensions via CLI
IMAGES+=("${EXTRA_IMAGES[@]}")

(( ${#IMAGES[@]} > 0 )) || die "${E_INVALID_INPUT}" "No images found. Check versions.env or add --image."

# --- Main -----------------------------------------------------------------------
main() {
  log_info "🚀 Creating air-gapped bundle"
  log_info "Output dir: ${OUT_DIR}"
  log_info "Archive name: ${ARCHIVE_NAME}.tar.gz"
  log_info "Image compression: ${COMPRESSION}"
  log_info "Images (${#IMAGES[@]}):"
  for i in "${IMAGES[@]}"; do log_info "  - ${i}"; done

  if [[ -e "${OUT_DIR}" ]]; then
    log_warn "Output directory already exists: ${OUT_DIR}"
    confirm_or_exit "Continue and reuse directory?"
  fi

  mkdir -p "${OUT_DIR}"
  # Clean up OUT_DIR on failure (but keep on success). We register a cleanup,
  # and later disable it when we succeed.
  register_cleanup "rm -rf '${OUT_DIR}'"

  # 1) Ensure runtime is ready and summarized
  detect_container_runtime
  runtime_summary

  # 2) Build the images bundle inside OUT_DIR (manifest + checksums + versions.env)
  #    This pulls, saves images.tar(.gz/.zst), writes SHA256SUMS and manifest.json
  create_airgapped_bundle "${OUT_DIR}" "${IMAGES[@]}"

  # 3) Add scripts/configs to the bundle directory
  log_info "Adding scripts and configs to bundle directory..."
  # Always include these if present
  declare -a DEFAULT_INCLUDES=( "airgapped-quickstart.sh" "docker-compose.yml" "versions.env" "lib" "config" )
  DEFAULT_INCLUDES+=("${EXTRA_INCLUDES[@]}")
  for path in "${DEFAULT_INCLUDES[@]}"; do
    [[ -e "${SCRIPT_DIR}/${path}" ]] || { log_warn "Skip missing path: ${path}"; continue; }
    # Preserve mode/timestamps; avoid following symlinks outside tree
    if [[ -d "${SCRIPT_DIR}/${path}" ]]; then
      cp -a "${SCRIPT_DIR}/${path}" "${OUT_DIR}/"
    else
      cp -a "${SCRIPT_DIR}/${path}" "${OUT_DIR}/"
    fi
    log_debug "  -> Included: ${path}"
  done

  # 4) Create the final distributable tarball of the OUT_DIR (separate from images.tar.*)
  mkdir -p "$(dirname "dist")" 2>/dev/null || true
  local parent dirbase archive
  parent="$(dirname -- "${OUT_DIR}")"
  dirbase="$(basename -- "${OUT_DIR}")"
  archive="${ARCHIVE_NAME}.tar.gz"

  if [[ -f "${archive}" ]]; then
    log_warn "Archive already exists: ${archive}"
    confirm_or_exit "Overwrite existing archive?"
    rm -f "${archive}" "${archive}.sha256"
  fi

  log_info "Packing final bundle archive: ${archive}"
  # Normalize owner/group for reproducibility; ignore failures if tar variant lacks flags
  ( cd "${parent}" && tar --owner=0 --group=0 -czf "${OLDPWD}/${archive}" "${dirbase}" ) || \
  ( cd "${parent}" && tar -czf "${OLDPWD}/${archive}" "${dirbase}" )

  # 5) Checksum for final archive
  generate_checksum_file "${archive}"

  # Success: keep OUT_DIR; remove cleanup
  # Replace cleanup with a no-op to preserve artifacts
  register_cleanup ":"  # neutralize later cleanups
  log_success "✅ Air-gapped bundle created."
  log_info "Bundle dir: ${OUT_DIR}"
  log_info "Archive:    ${archive}"
  log_info "Checksum:   ${archive}.sha256"
  log_info "Transfer BOTH files to the target machine."
}

main "$@"
