#!/usr/bin/env bash
# ==============================================================================
# airgapped-quickstart.sh
# Deploy from an air-gapped bundle on the offline target machine.
#
# Features:
#   - Verifies and loads images from bundle dir or images.tar[.gz|.zst]
#   - Starts the stack via unified 'compose' runner (Docker or Podman)
#   - Basic health checks for required services
#
# Flags:
#   --yes, -y                Non-interactive (assume yes)
#   --compose-file <path>    Compose file to use (default: ./docker-compose.yml)
#   --wait <seconds>         Wait after 'up -d' before health checks (default: 20)
#   -h, --help               Show usage
#
# Env overrides:
#   REQUIRED_SERVICES="app redis"   Space-separated list to health-check
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/air-gapped.sh
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# --- Locate bundle root / libs --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BUNDLE_ROOT="${SCRIPT_DIR}"

# Sanity: require lib/ and at least a compose file or manifest
if [[ ! -d "${BUNDLE_ROOT}/lib" ]]; then
  echo "FATAL: Expected 'lib/' directory in the bundle root." >&2
  exit 1
fi

# shellcheck source=lib/core.sh
source "${BUNDLE_ROOT}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${BUNDLE_ROOT}/lib/error-handling.sh"
# shellcheck source=lib/runtime-detection.sh
source "${BUNDLE_ROOT}/lib/runtime-detection.sh"
# shellcheck source=lib/air-gapped.sh
source "${BUNDLE_ROOT}/lib/air-gapped.sh"

# --- Defaults / Flags -----------------------------------------------------------
AUTO_YES=0
COMPOSE_FILE="${BUNDLE_ROOT}/docker-compose.yml"
WAIT_SECONDS=20
# Default required services; override via env REQUIRED_SERVICES="a b c"
: "${REQUIRED_SERVICES:=app redis}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Deploys the application from an air-gapped bundle.

Options:
  --yes, -y                Run non-interactively (assume yes)
  --compose-file <path>    Path to docker-compose.yml (default: ${COMPOSE_FILE})
  --wait <seconds>         Wait time before health checks (default: ${WAIT_SECONDS})
  -h, --help               Show this help

This script must be run from the root of the unpacked bundle.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) AUTO_YES=1; shift;;
    --compose-file) COMPOSE_FILE="${2:?}"; shift 2;;
    --wait) WAIT_SECONDS="${2:?}"; shift 2;;
    -h|--help) usage; exit 0;;
    *) die "${E_INVALID_INPUT}" "Unknown option: $1";;
  esac
done

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

# Try to find an images archive in the bundle root if manifest is missing
_find_archive_path() {
  if [[ -f "${BUNDLE_ROOT}/manifest.json" ]]; then
    # lib/air-gapped.sh can read it directly via load_airgapped_bundle
    echo "BUNDLE"
    return 0
  fi
  for f in images.tar images.tar.gz images.tar.zst; do
    if [[ -f "${BUNDLE_ROOT}/${f}" ]]; then
      echo "${BUNDLE_ROOT}/${f}"
      return 0
    fi
  done
  echo ""
  return 1
}

# --- Main -----------------------------------------------------------------------
main() {
  log_info "📦 Air-gapped quickstart initiated..."

  # 1) Detect runtime and summarize
  detect_container_runtime
  runtime_summary

  # 2) Verify and load images
  local archive
  archive="$(_find_archive_path || true)"

  if [[ -z "${archive}" ]]; then
    die "${E_INVALID_INPUT}" "No images archive found. Expected manifest.json or images.tar[.gz|.zst] in bundle root."
  fi

  if [[ "${archive}" == "BUNDLE" ]]; then
    log_info "Found manifest.json; loading bundle directory '${BUNDLE_ROOT}'..."
    load_airgapped_bundle "${BUNDLE_ROOT}"
  else
    log_info "Loading images from archive: ${archive}"
    load_image_archive "${archive}"
  fi

  # 3) Start the stack
  [[ -f "${COMPOSE_FILE}" ]] || die "${E_INVALID_INPUT}" "Compose file not found: ${COMPOSE_FILE}"
  log_info "🚀 Starting services with: ${COMPOSE_FILE}"

  # Use retry for flaky first boots
  with_retry --retries 3 --base-delay 3 --max-delay 15 -- \
    compose -f "${COMPOSE_FILE}" up -d --remove-orphans

  log_info "⏳ Waiting ${WAIT_SECONDS}s for services to stabilize..."
  sleep "${WAIT_SECONDS}"

  # 4) Health checks
  log_info "🩺 Running health checks..."
  local all_ok=0
  for svc in ${REQUIRED_SERVICES}; do
    # Get container ID for the service
    local cid
    cid="$(compose -f "${COMPOSE_FILE}" ps -q "${svc}" || true)"
    if [[ -z "${cid}" ]]; then
      log_error "❌ Service '${svc}' has no running container."
      all_ok=1
      continue
    fi
    # Inspect via runtime
    local status
    status="$("${CONTAINER_RUNTIME}" inspect --format '{{.State.Status}}' "${cid}" 2>/dev/null || echo "unknown")"
    if [[ "${status}" == "running" ]]; then
      log_success "✔ '${svc}' is running."
    else
      log_error "❌ '${svc}' status: ${status}"
      all_ok=1
    fi
  done

  if (( all_ok != 0 )); then
    log_error "Some services are not healthy. Recent status:"
    compose -f "${COMPOSE_FILE}" ps || true
    die "${E_GENERAL}" "One or more services failed to start. Check logs with: compose -f '${COMPOSE_FILE}' logs -f"
  fi

  log_success "✅ Air-gapped deployment complete. All required services are running."
  log_info "View logs:   compose -f '${COMPOSE_FILE}' logs -f"
  log_info "Stop stack:  compose -f '${COMPOSE_FILE}' down"
}

main "$@"
