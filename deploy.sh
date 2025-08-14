```bash
#!/usr/bin/env bash
#
# deploy.sh — One-shot wrapper for Easy Splunk
#
# Orchestrates: config selection → (optional) creds → digest resolution → deploy → (optional) Splunk config → (optional) health check.
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
#   --skip-digests              Skip image digest resolution (use existing versions.env)
#   --config-file <FILE>        Check legacy v2.0 config for migration issues
#   -h | --help                 Show help
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, generate-credentials.sh,
#               orchestrator.sh, generate-splunk-configs.sh, health_check.sh, resolve-digests.sh,
#               integration-guide.sh
# Notes:
# - Expects to run from the repo root.
# - Uses orchestrator's --config flag to load a template.
# - Creates temporary override config for --no-monitoring.
# Version: 1.0.0
#

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
cd "$SCRIPT_DIR"

# --- Source core libs
source "./lib/core.sh"
source "./lib/error-handling.sh"
source "./lib/security.sh"

# --- Version Checks ---
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "deploy.sh requires security.sh version >= 1.0.0"
fi

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
SKIP_DIGESTS="false"
CONFIG_FILE=""
: "${SECRETS_DIR:=./secrets}"
CONFIG_DIR="./config"
TEMPLATES_DIR="./config-templates"
ACTIVE_CONFIG=""
TEMP_OVERRIDE_CONFIG=""

# --- Helpers
usage() {
  sed -n '1,100p' "$0" | sed -n '1,40p' | sed 's/^# \{0,1\}//'
  exit 0
}

cleanup() {
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
    --skip-digests)     SKIP_DIGESTS="true"; shift ;;
    --config-file)      CONFIG_FILE="${2:-}"; shift 2 ;;
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
    ACTIVE_CONFIG="$SIZE_OR_CONF"
    ;;
esac

if [[ ! -f "$ACTIVE_CONFIG" ]]; then
  die "$E_INVALID_INPUT" "Config not found: ${ACTIVE_CONFIG}"
fi

mkdir -p "$CONFIG_DIR" "$SECRETS_DIR"
harden_file_permissions "$CONFIG_DIR" "700" "config directory" || true
harden_file_permissions "$SECRETS_DIR" "700" "secrets directory" || true
harden_file_permissions "$ACTIVE_CONFIG" "600" "active config" || true

# --- Check legacy config
if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
  log_info "📋 Checking legacy v2.0 configuration: ${CONFIG_FILE}"
  ./integration-guide.sh "$CONFIG_FILE" --output text
  log_warn "Review migration issues above before proceeding."
fi

# --- Resolve image digests
if ! is_true "$SKIP_DIGESTS"; then
  log_info "📸 Resolving image digests in versions.env..."
  require_file "./resolve-digests.sh"
  ./resolve-digests.sh
else
  log_info "📸 Skipping digest resolution (per --skip-digests)."
fi

# --- Create override config for --no-monitoring
if is_true "$FORCE_NO_MONITORING"; then
  TEMP_OVERRIDE_CONFIG="$(mktemp -t easy-splunk-override-XXXX.conf)"
  cat "$ACTIVE_CONFIG" > "$TEMP_OVERRIDE_CONFIG"
  printf '\n# Wrapper override\nENABLE_MONITORING="false"\n' >> "$TEMP_OVERRIDE_CONFIG"
  harden_file_permissions "$TEMP_OVERRIDE_CONFIG" "600" "override config" || true
  ACTIVE_CONFIG="$TEMP_OVERRIDE_CONFIG"
  log_info "Monitoring disabled via wrapper override."
fi

# --- Show plan
log_info "📄 Using config: ${ACTIVE_CONFIG}"
if ! is_empty "$INDEX_NAME"; then
  log_info "🗂  Will configure Splunk index: ${INDEX_NAME}"
fi

# --- Preflight checks
require_file "./orchestrator.sh"
require_file "./generate-credentials.sh"
require_file "./health_check.sh"
require_file "./generate-splunk-configs.sh"
require_file "./versions.env"

# --- Generate credentials
if ! is_true "$SKIP_CREDS"; then
  log_info "🔐 Generating credentials and self-signed certificates..."
  yes | ./generate-credentials.sh
else
  log_info "🔐 Skipping credential generation (per --skip-creds)."
fi

# --- Deploy
log_info "🚀 Launching orchestrator..."
./orchestrator.sh --config "$ACTIVE_CONFIG"

# --- Configure Splunk index
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

# --- Health check
if ! is_true "$SKIP_HEALTH"; then
  log_info "🩺 Running post-deployment health check..."
  ./health_check.sh
else
  log_info "🩺 Skipping health check (per --skip-health)."
fi

# --- Audit security
audit_security_configuration "${SCRIPT_DIR}/security-audit.txt"

log_success "✅ Deployment complete. Splunk UI should be available at http://localhost:8000"
```