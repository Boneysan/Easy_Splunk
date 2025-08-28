#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

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

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load versions.env to get image references
if [[ -f "${SCRIPT_DIR}/versions.env" ]]; then
    source "${SCRIPT_DIR}/versions.env" || error_exit "Failed to load versions.env"
