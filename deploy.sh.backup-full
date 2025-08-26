#!/usr/bin/env bash
# Easy_Splunk - Combined deployment script (hardened)
# - Verifies runtime + compose, validates compose services
# - Prefers Docker (falls back to Podman)
# - Two-phase-safe (exit 78 if docker group needs re-login)
# - Optional monitoring stack
# - Credentials handling with safer defaults
# - Health checks + Splunk readiness polling (8089)
# - Index creation after readiness
# - Persisted state marker (config/active.conf)
# - Cleanup/rollback on failure

set -euo pipefail

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Initialize all variables first (required by functions)
SIZE="${SIZE:-small}"              # small|medium|large
WITH_MONITORING=0
DRY_RUN=0
NO_BUILD=0
FORCE_RECREATE=0
FORCE_DEPLOY=0
SKIP_CREDS=0
SKIP_HEALTH=0
DEBUG_MODE=0
QUIET=0
NON_INTERACTIVE=0
ENVFILE=""
INDEX_NAME=""
SPLUNK_USER="${SPLUNK_USER:-admin}"
SPLUNK_PASSWORD="${SPLUNK_PASSWORD:-}"

# Whether to include SPLUNK_PASSWORD in the generated .env (safer default: 0)
WRITE_PASSWORD_TO_ENV="${WRITE_PASSWORD_TO_ENV:-0}"

# Runtime detection
RUNTIME=""
COMPOSE=""
DEPLOYMENT_ID="$(date +%Y%m%d_%H%M%S)"

# File paths
BASE_COMPOSE="${BASE_COMPOSE:-$SCRIPT_DIR/compose.yaml}"
ALT_BASE_COMPOSE="${ALT_BASE_COMPOSE:-$SCRIPT_DIR/docker-compose.yml}"
MON_COMPOSE="${MON_COMPOSE:-$SCRIPT_DIR/compose.monitoring.yaml}"
ALT_MON_COMPOSE="${ALT_MON_COMPOSE:-$SCRIPT_DIR/docker-compose.monitoring.yml}"
CONFIG_DIR="${SCRIPT_DIR}/config"
CREDS_DIR="${SCRIPT_DIR}/credentials"
LOG_FILE="/tmp/easy_splunk_deploy_${DEPLOYMENT_ID}.log"
ACTIVE_MARKER="${CONFIG_DIR}/active.conf"
ENV_FILE="${SCRIPT_DIR}/.env"
CREDS_USER_FILE="${CREDS_DIR}/splunk_admin_user"
CREDS_PASS_FILE="${CREDS_DIR}/splunk_admin_password"

# Constants
readonly MIN_PASSWORD_LENGTH=8
readonly RESERVED_INDEXES=("_audit" "_internal" "_introspection" "main" "history" "summary")
readonly MAX_PASSWORD_ATTEMPTS=10

# Deployment-state flag for cleanup on failure
STARTED_DEPLOY=0
CREDENTIALS_GENERATED=0
ENV_GENERATED=0

# Load versions.env to get image references
if [[ -f "${SCRIPT_DIR}/versions.env" ]]; then
    source "${SCRIPT_DIR}/versions.env" || {
        echo "ERROR: Failed to load versions.env" >&2
        exit 1
    }
else
    echo "ERROR: versions.env not found - required for image references" >&2
    exit 1
fi

# ============================= Colors & Logging ================================
NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'

log_message() {
    local level="$1"; shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    if (( QUIET )) && [[ "$level" == "INFO" || "$level" == "SUCCESS" ]]; then return; fi
    case "$level" in
        INFO)    printf "%b[INFO ]%b [%s] %s\n" "$BLUE"   "$NC" "$timestamp" "$*";;
        SUCCESS|OK)
                 printf "%b[ OK  ]%b [%s] %s\n" "$GREEN"  "$NC" "$timestamp" "$*";;
        WARN)    printf "%b[WARN ]%b [%s] %s\n" "$YELLOW" "$NC" "$timestamp" "$*";;
        ERROR|FAIL)
                 printf "%b[ERROR]%b [%s] %s\n" "$RED"    "$NC" "$timestamp" "$*" >&2;;
        DEBUG)
            if [[ "${DEBUG_MODE:-0}" == "1" || "${DEBUG:-false}" == "true" ]]; then
                printf "%b[DEBUG]%b [%s] %s\n" "$NC" "$NC" "$timestamp" "$*"
            fi
            ;;
    esac
}

error_exit() { log_message ERROR "$1"; exit "${2:-1}"; }

# Redact password if the shell ever dumps env or on exit
trap 'unset SPLUNK_PASSWORD' EXIT

# Cleanup on failure (best-effort rollback) — set EARLY so we catch early errors
on_error() {
    local ec=$?
    # If we already redirected to the log, keep messages going there too
    if (( ec != 0 )); then
        log_message ERROR "deploy.sh failed with exit code ${ec}"
        if (( STARTED_DEPLOY )) && [[ -n "${COMPOSE:-}" ]]; then
            # Split COMPOSE into binary + optional subcommand (e.g., "docker compose")
            local _cbin _csub
            read -r _cbin _csub <<<"$COMPOSE"
            if command -v "$_cbin" >/dev/null 2>&1; then
                log_message WARN "Attempting cleanup: bringing stack down..."
                if [[ -n "$_csub" ]]; then
                    "$_cbin" "$_csub" "${COMPOSE_FILES[@]}" down || true
                else
                    "$_cbin" "${COMPOSE_FILES[@]}" down || true
                fi
            fi
        fi
        # Clean up generated files
        if (( CREDENTIALS_GENERATED )); then
            log_message WARN "Cleaning up generated credential files..."
            rm -f "${CREDS_USER_FILE}" "${CREDS_PASS_FILE}" || true
        fi
        if (( ENV_GENERATED )); then
            log_message WARN "Cleaning up generated .env file..."
            rm -f "${ENV_FILE}" || true
        fi
    fi
    exit "$ec"
}
trap on_error ERR

# ============================= Usage ==========================================
usage() {
    cat << EOF
Usage: $0 [size] [options]

SIZES:
  small     - 1 indexer, 1 search head (default)
  medium    - 2 indexers, 1 search head  
  large     - 3 indexers, 2 search heads

OPTIONS:
  --monitoring        Enable monitoring stack (Prometheus + Grafana)
  --dry-run          Show what would be deployed without actually deploying
  --force-recreate   Force recreation of all containers
  --force-deploy     Skip deployment state checks
  --skip-creds       Skip credential generation (use existing)
  --skip-health      Skip health checks after deployment
  --quiet            Suppress informational output
  --debug            Enable debug output
  --non-interactive  Run without prompts (use defaults)
  --env-file FILE    Use custom environment file
  --index NAME       Create a custom index after deployment
  --help             Show this help message

ENVIRONMENT VARIABLES:
  SPLUNK_USER        Splunk admin username (default: admin)
  SPLUNK_PASSWORD    Splunk admin password (will prompt if not set)
  SIZE               Deployment size (small|medium|large)
  WITH_MONITORING    Enable monitoring (0|1)
  SIMPLE_CREDS       Use simple credential mode, bypass encryption (0|1)

EXAMPLES:
  $0                           # Deploy small cluster
  $0 medium --monitoring       # Deploy medium cluster with monitoring
  $0 large --dry-run          # Show what large deployment would look like
  $0 --index myapp_logs       # Deploy and create custom index
  
NOTES:
  - First run may require docker group setup (will exit with code 78)
  - Logs are written to /tmp/easy_splunk_deploy_TIMESTAMP.log
  - State is tracked in config/active.conf for cleanup purposes
EOF
}

echo "Easy_Splunk deployment script loaded successfully!"
echo "Run with --help for usage information."
echo "This is a minimal working version - full functions need to be added."
