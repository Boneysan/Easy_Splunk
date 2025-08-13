#!/usr/bin/env bash
#
# deploy.sh — One-shot wrapper for Easy Splunk
#
# Orchestrates: config selection → (optional) creds → deploy → (optional) Splunk config → (optional) health check.
#
# Usage:
#   ./deploy.sh <small|medium|large|/path/to/conf> [options]
#
# Options:
#   --index-name <NAME>         Create/configure this index in Splunk after deploy
#   --splunk-user <USER>        Splunk admin username   (default: admin)
#   --splunk-password <PASS>    Splunk admin password   (default: prompt if not provided)
#   --splunk-api-host <HOST>    Splunk mgmt API host    (default: 127.0.0.1)
#   --splunk-api-port <PORT>    Splunk mgmt API port    (default: 8089)
#   --no-monitoring             Force-disable Prometheus+Grafana even if config enables it
#   --skip-creds                Skip credential/cert generation (reuse existing)
#   --skip-health               Skip post-deploy health check
#   -h | --help                 Show help
#
# Notes:
# - This script expects to run from the repo root.
# - It uses orchestrator's --config flag to load a template.
# - To disable monitoring, we create a temporary override config.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

# --- Source core libs for logging & error handling
source "./lib/core.sh"
source "./lib/error-handling.sh"

# --- Defaults
SIZE_OR_CONF=""
INDEX_NAME=""
SPLUNK_USER="admin"
SPLUNK_PASSWORD=""
SPLUNK_API_HOST="127.0.0.1"
SPLUNK_API_PORT="8089"
FORCE_NO_MONITORING="false"
SKIP_CREDS="false"
SKIP_HEALTH="false"

CONFIG_DIR="./config"
TEMPLATES_DIR="./config-templates"
ACTIVE_CONFIG=""              # resolved later
TEMP_OVERRIDE_CONFIG=""       # if --no-monitoring, we create one

# --- Helpers
usage() {
  sed -n '1,100p' "$0" | sed -n '1,40p' | sed 's/^# \{0,1\}//'
  exit 0
}

cleanup() {
  # Remove temp override config if created
  if [[ -n "${TEMP_OVERRIDE_CONFIG:-}" && -f "$TEMP_OVERRIDE_CONFIG" ]]; then
    rm -f "$TEMP_OVERRIDE_CONFIG" || true
  fi
}
add_cleanup_task "cleanup"

require_file() {
  local f="$1"
  [[ -f "$f" ]] || die "$E_MISSING_DEP" "Required file not found: $f"
}

# --- Parse args
if [[ $# -lt 1 ]]; then
  usage
fi

SIZE_OR_CONF="$1"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --index-name)       INDEX_NAME="${2:-}"; shift 2 ;;
    --splunk-user)      SPLUNK_USER="${2:-}"; shift 2 ;;
    --splunk-password)  SPLUNK_PASSWORD="${2:-}"; shift 2 ;;
    --splunk-api-host)  SPLUNK_API_HOST="${2:-}"; shift 2 ;;
    --splunk-api-port)  SPLUNK_API_PORT="${2:-}"; shift 2 ;;
    --no-monitoring)    FORCE_NO_MONITORING="true"; shift ;;
    --skip-creds)       SKIP_CREDS="true"; shift ;;
    --skip-health)      SKIP_HEALTH="true"; shift ;;
    -h|--help)          usage ;;
    *) die "$E_INVALID_INPUT" "Unknown option: $1" ;;
  esac
done

# --- Resolve config
case "$SIZE_OR_CONF" in
  small|small-production)   ACTIVE_CONFIG="${TEMPLATES_DIR}/small-production.conf" ;;
  medium|medium-production) ACTIVE_CONFIG="${TEMPLATES_DIR}/medium-production.conf" ;;
  large|large-production)   ACTIVE_CONFIG="${TEMPLATES_DIR}/large-production.conf" ;;
  *)
    # treat as file path
    ACTIVE_CONFIG="$SIZE_OR_CONF"
    ;;
esac

if [[ ! -f "$ACTIVE_CONFIG" ]]; then
  die "$E_INVALID_INPUT" "Config not found: ${ACTIVE_CONFIG}"
fi

mkdir -p "$CONFIG_DIR"

# If user requested --no-monitoring, create a temporary override config
if is_true "$FORCE_NO_MONITORING"; then
  TEMP_OVERRIDE_CONFIG="$(mktemp -t easy-splunk-override-XXXX.conf)"
  # Copy the base template, then override the flag
  cat "$ACTIVE_CONFIG" > "$TEMP_OVERRIDE_CONFIG"
  printf '\n# Wrapper override\nENABLE_MONITORING="false"\n' >> "$TEMP_OVERRIDE_CONFIG"
  ACTIVE_CONFIG="$TEMP_OVERRIDE_CONFIG"
  log_info "Monitoring disabled via wrapper override."
fi

# --- Show plan
log_info "📄 Using config: ${ACTIVE_CONFIG}"
if ! is_empty "$INDEX_NAME"; then
  log_info "🗂  Will configure Splunk index: ${INDEX_NAME}"
fi

# --- Preflight checks (files we will call)
require_file "./orchestrator.sh"
require_file "./generate-credentials.sh"
require_file "./health_check.sh"
require_file "./generate-splunk-configs.sh"

# --- Optional credentials
if ! is_true "$SKIP_CREDS"; then
  log_info "🔐 Generating credentials and self-signed certificates..."
  yes | ./generate-credentials.sh
else
  log_info "🔐 Skipping credential generation (per --skip-creds)."
fi

# --- Deploy
log_info "🚀 Launching orchestrator..."
# Pass the chosen config; monitoring is driven by that config (or wrapper override)
./orchestrator.sh --config "$ACTIVE_CONFIG"

# --- Optional Splunk config (index creation)
if ! is_empty "$INDEX_NAME"; then
  log_info "⚙️  Configuring Splunk index '${INDEX_NAME}' via API..."
  GEN_ARGS=(--splunk-user "$SPLUNK_USER" --index-name "$INDEX_NAME" --splunk-api-host "$SPLUNK_API_HOST" --splunk-api-port "$SPLUNK_API_PORT")
  if [[ -n "$SPLUNK_PASSWORD" ]]; then
    GEN_ARGS+=(--splunk-password "$SPLUNK_PASSWORD")
  fi
  ./generate-splunk-configs.sh "${GEN_ARGS[@]}"
else
  log_info "ℹ️  No --index-name provided; skipping Splunk API configuration."
fi

# --- Optional health check
if ! is_true "$SKIP_HEALTH"; then
  log_info "🩺 Running post-deployment health check..."
  ./health_check.sh
else
  log_info "🩺 Skipping health check (per --skip-health)."
fi

log_success "✅ Deployment complete. Splunk UI should be available at http://localhost:8000"
