#!/bin/bash
# deploy.sh - Complete deployment wrapper with comprehensive error handling
# Main entry point for Easy_Splunk cluster deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source core libraries first (required by other modules)
source "${SCRIPT_DIR}/lib/core.sh" || {
    echo "ERROR: Cannot load core library from lib/core.sh" >&2
    exit 1
}
```bash
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

# Defaults / Flags
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

Sizes:
  small | medium | large     Deploy cluster of specified size (default: $SIZE)

Options:
  --with-monitoring          Include monitoring stack (Prometheus/Grafana)
  --no-monitoring            Disable monitoring stack
  --env-file <path>          Use specified environment file
  --index-name NAME          Create and configure a Splunk index
  --splunk-user USER         Splunk admin username (default: admin)
  --splunk-password PASS     Splunk admin password (will prompt if not provided)
  --skip-creds               Skip credential generation/validation
  --skip-health              Skip post-deployment health checks
  --no-build                 Skip image building; only pull/up
  --force-recreate           Force recreation of containers
  --force                    Force deployment even if an active marker is present
  --dry-run                  Show commands without executing
  --debug                    Enable debug output
  --quiet                    Suppress INFO and SUCCESS logs (only show WARN/ERROR)
  --non-interactive          No prompts; auto-generate password if needed; error on conflicts
  -h, --help                 Show this help

Environment:
  SIZE=small|medium|large
  WRITE_PASSWORD_TO_ENV=0|1    (default 0; 1 writes SPLUNK_PASSWORD into .env)
  BASE_COMPOSE, ALT_BASE_COMPOSE, MON_COMPOSE, ALT_MON_COMPOSE

Exit codes:
  0   Success
  1   Generic failure
  78  Re-login required (Docker group membership not active in current shell)
EOF
}

# ============================= Argument Parsing ===============================
parse_arguments() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            small|medium|large) SIZE="$1"; shift;;
            --with-monitoring)  WITH_MONITORING=1; shift;;
            --no-monitoring)    WITH_MONITORING=0; shift;;
            --env-file)
                ENVFILE="${2:-}"; [[ -z "$ENVFILE" ]] && error_exit "--env-file requires a path"
                [[ ! -f "$ENVFILE" ]] && error_exit "Environment file not found: $ENVFILE"
                shift 2;;
            --index-name)       INDEX_NAME="$2"; validate_index_name "$INDEX_NAME"; shift 2;;
            --splunk-user)      SPLUNK_USER="$2"; validate_username "$SPLUNK_USER"; shift 2;;
            --splunk-password)  SPLUNK_PASSWORD="$2"; shift 2;;
            --skip-creds)       SKIP_CREDS=1; shift;;
            --skip-health)      SKIP_HEALTH=1; shift;;
            --no-build)         NO_BUILD=1; shift;;
            --force-recreate)   FORCE_RECREATE=1; shift;;
            --force)            FORCE_DEPLOY=1; shift;;
            --dry-run)          DRY_RUN=1; shift;;
            --debug)            DEBUG_MODE=1; export DEBUG=true; shift;;
            --quiet)            QUIET=1; shift;;
            --non-interactive)  NON_INTERACTIVE=1; shift;;
            -h|--help)          usage; exit 0;;
            *)                  args+=("$1"); shift;;
        esac
    done
    set -- "${args[@]}"
    log_message INFO "Configuration: size=$SIZE, monitoring=$WITH_MONITORING"
}

# ============================= Validation Helpers =============================
validate_index_name() {
    local index="$1"
    (( ${#index} <= 64 )) || error_exit "Index name too long (max 64 chars): $index"
    [[ "$index" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]] || error_exit "Index must start with a letter; only letters/digits/underscores: $index"
    for reserved in "${RESERVED_INDEXES[@]}"; do
        [[ "$index" == "$reserved" ]] && error_exit "Cannot use reserved index name: $index"
    done
    log_message DEBUG "Index name validated: $index"
}

validate_username() {
    local user="$1"
    [[ "$user" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || error_exit "Username must start with a letter; only letters/digits/[_-]"
}

validate_password() {
    local password="$1"; local errs=()
    [[ ${#password} -ge $MIN_PASSWORD_LENGTH ]] || errs+=("at least $MIN_PASSWORD_LENGTH characters")
    [[ "$password" =~ [A-Z] ]] || errs+=("uppercase letter")
    [[ "$password" =~ [a-z] ]] || errs+=("lowercase letter")
    [[ "$password" =~ [0-9] ]] || errs+=("number")
    [[ "$password" =~ [^a-zA-Z0-9] ]] || errs+=("special character")
    [[ -n "${SPLUNK_USER:-}" && "$password" == *"$SPLUNK_USER"* ]] && errs+=("cannot contain username")
    if ((${#errs[@]})); then
        log_message ERROR "Password validation failed. Requirements:"
        for e in "${errs[@]}"; do log_message ERROR "  - $e"; done
        return 1
    fi
    return 0
}

generate_random_password() {
    local attempts=0
    while (( attempts < MAX_PASSWORD_ATTEMPTS )); do
        if command -v openssl >/dev/null 2>&1; then
            local password
            password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c 12)
            if validate_password "$password"; then
                echo "$password"
                return 0
            fi
        else
            error_exit "Cannot generate password in non-interactive mode without openssl"
        fi
        attempts=$((attempts + 1))
        log_message DEBUG "Password generation attempt $attempts failed validation; retrying..."
    done
    error_exit "Failed to generate a valid password after $MAX_PASSWORD_ATTEMPTS attempts"
}

check_disk_space() {
    local required_gb="$1"
    local available_gb
    if command -v df >/dev/null 2>&1; then
        available_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
        if [[ ${available_gb:-0} -lt $required_gb ]]; then
            error_exit "Insufficient disk space: ${available_gb}GB available, ${required_gb}GB required"
        fi
        log_message SUCCESS "Disk space check passed: ${available_gb}GB available"
    else
        log_message WARN "Cannot check disk space (df not available)"
    fi
}

check_port_conflicts() {
    local ports=(8000 8089)
    (( WITH_MONITORING )) && ports+=(9090 3000)

    local conflicts=()
    for port in "${ports[@]}"; do
        if command -v ss >/dev/null 2>&1; then
            ss -Htnl "( sport = :$port )" | grep -q . && conflicts+=("$port")
        elif command -v netstat >/dev/null 2>&1; then
            # strict match on the port number at end of address field
            if netstat -tnl 2>/dev/null \
                | awk '{print $4}' \
                | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' \
                | awk -v p="$port" '$0==p{found=1} END{exit !found}'; then
                conflicts+=("$port")
            fi
        fi
    done

    if ((${#conflicts[@]})); then
        log_message WARN "Port conflicts detected: ${conflicts[*]}"
        if (( NON_INTERACTIVE )); then
            if (( FORCE_DEPLOY )); then
                log_message INFO "Non-interactive with --force: Proceeding despite port conflicts"
            else
                error_exit "Non-interactive: Port conflicts detected (use --force to override)"
            fi
        else
            if (( ! FORCE_DEPLOY )); then
                read -p "Continue anyway? [y/N]: " -r ans; echo
                [[ "$ans" =~ ^[Yy]$ ]] || error_exit "Deployment cancelled due to port conflicts"
            fi
        fi
    fi
}

# ============================= Runtime Detection ==============================
detect_runtime() {
    if command -v docker >/dev/null 2>&1; then
        RUNTIME="docker"
    elif command -v podman >/dev/null 2>&1; then
        RUNTIME="podman"
    else
        error_exit "Neither Docker nor Podman is installed. Please install a container runtime first."
    fi
    log_message SUCCESS "Container runtime detected: $RUNTIME"
}

detect_compose() {
    if [[ "$RUNTIME" == "docker" ]]; then
        if docker compose version >/dev/null 2>&1; then
            COMPOSE="docker compose"
        else
            error_exit "Docker Compose plugin not found. Install docker-compose-plugin."
        fi
    else
        if podman compose version >/dev/null 2>&1; then
            COMPOSE="podman compose"
        elif command -v podman-compose >/dev/null 2>&1; then
            COMPOSE="podman-compose"
        else
            error_exit "Podman compose not found. Install podman-compose."
        fi
    fi
    log_message SUCCESS "Compose command detected: $COMPOSE"
}

verify_runtime() {
    if [[ "$RUNTIME" == "docker" ]]; then
        if ! docker info >/dev/null 2>&1; then
            log_message ERROR "Docker installed but daemon not accessible by current user."
            log_message INFO "If you just added your user to the 'docker' group, log out and back in, then re-run the command."
            exit 78
        fi
        log_message SUCCESS "Docker daemon accessible"
    else
        if ! podman info >/dev/null 2>&1; then
            error_exit "Podman not functional for current user"
        fi
        log_message SUCCESS "Podman functional"
    fi
}

# ============================= Compose File Management ========================
find_base_compose() {
    if [[ -f "$BASE_COMPOSE" ]]; then
        echo "$BASE_COMPOSE"
    elif [[ -f "$ALT_BASE_COMPOSE" ]]; then
        echo "$ALT_BASE_COMPOSE"
    else
        error_exit "No base compose file found. Expected: $BASE_COMPOSE or $ALT_BASE_COMPOSE"
    fi
}

find_monitoring_compose() {
    if [[ -f "$MON_COMPOSE" ]]; then
        echo "$MON_COMPOSE"
    elif [[ -f "$ALT_MON_COMPOSE" ]]; then
        echo "$ALT_MON_COMPOSE"
    else
        echo ""
    fi
}

build_compose_command() {
    local base_compose
    base_compose="$(find_base_compose)"

    local compose_files=("-f" "$base_compose")
    local compose_opts=()

    if (( WITH_MONITORING )); then
        local mon_compose
        mon_compose="$(find_monitoring_compose)"
        if [[ -n "$mon_compose" ]]; then
            compose_files+=("-f" "$mon_compose")
            log_message SUCCESS "Monitoring compose file included: $mon_compose"
        else
            log_message WARN "Monitoring requested but no monitoring compose file found"
        fi
    fi

    # Prefer compose profiles (small|medium|large)
    export COMPOSE_PROFILES="$SIZE"
    log_message INFO "Using compose profile: $COMPOSE_PROFILES"

    [[ -n "$ENVFILE" ]] && compose_opts+=("--env-file" "$ENVFILE")
    (( NO_BUILD )) && compose_opts+=("--no-build")
    (( FORCE_RECREATE )) && compose_opts+=("--force-recreate")

    # Export for use in deploy phase
    COMPOSE_FILES=( "${compose_files[@]}" )
    COMPOSE_OPTS=( "${compose_opts[@]}" )
}

validate_compose_services() {
    # Ensure the expected minimum services exist in the resolved config
    local services
    if ! services="$($COMPOSE "${COMPOSE_FILES[@]}" config --services 2>/dev/null)"; then
        error_exit "Failed to parse compose services from configuration"
    fi
    if [[ "${DEBUG_MODE:-0}" == "1" || "${DEBUG:-false}" == "true" ]]; then
        printf "%b[DEBUG]%b [%s] Compose services:\n%s\n" "$NC" "$NC" "$(date '+%Y-%m-%d %H:%M:%S')" "$services"
    fi

    local required=(indexer)
    local missing=()
    for svc in "${required[@]}"; do
        if ! grep -q "^${svc}$" <<<"$services"; then
            missing+=("$svc")
        fi
    done
    if ((${#missing[@]})); then
        error_exit "Expected service(s) missing from compose: ${missing[*]}"
    fi
    log_message SUCCESS "Compose services validated (required present)"
}

# ============================= Credential Management ==========================
handle_credentials() {
    if (( SKIP_CREDS )); then
        log_message INFO "Skipping credential management"
        [[ -z "$SPLUNK_PASSWORD" ]] && error_exit "Password required when skipping credential generation (use --splunk-password)"
        return 0
    fi

    mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory"

    if [[ -z "$SPLUNK_PASSWORD" ]]; then
        if (( NON_INTERACTIVE )); then
            log_message INFO "Non-interactive mode: Generating random password"
            SPLUNK_PASSWORD=$(generate_random_password)
            log_message INFO "Generated password (hidden)"
        else
            log_message INFO "Password requirements: $MIN_PASSWORD_LENGTH+ chars, mixed case, numbers, special chars"
            while true; do
                read -s -p "Enter Splunk admin password: " SPLUNK_PASSWORD; echo
                read -s -p "Confirm password: " password_confirm; echo
                if [[ "$SPLUNK_PASSWORD" != "$password_confirm" ]]; then
                    log_message ERROR "Passwords do not match"; continue
                fi
                if validate_password "$SPLUNK_PASSWORD"; then break; fi
                log_message INFO "Please try again"
            done
        fi
    else
        validate_password "$SPLUNK_PASSWORD" || error_exit "Provided password did not meet requirements"
    fi

    echo -n "$SPLUNK_USER"     > "${CREDS_USER_FILE}"
    echo -n "$SPLUNK_PASSWORD" > "${CREDS_PASS_FILE}"
    chmod 600 "${CREDS_DIR}"/splunk_admin_* || true
    export SPLUNK_USER SPLUNK_PASSWORD
    CREDENTIALS_GENERATED=1
    log_message SUCCESS "Credentials prepared (stored in ${CREDS_DIR}/)"
}

create_env_file() {
    if [[ -n "$ENVFILE" ]]; then
        log_message INFO "External --env-file provided; skipping local .env generation"
        return 0
    fi
    local splunk_secret cluster_secret
    if command -v openssl >/dev/null 2>&1; then
        splunk_secret=$(openssl rand -hex 32)
        cluster_secret=$(openssl rand -hex 32)
    elif [[ -r /dev/urandom ]]; then
        splunk_secret="$(head -c 16 /dev/urandom | xxd -p)"
        cluster_secret="$(head -c 16 /dev/urandom | xxd -p)"
    else
        log_message WARN "No openssl or /dev/urandom; generating low-entropy fallback secrets (development only!)"
        splunk_secret="fallback_${DEPLOYMENT_ID}_$RANDOM"
        cluster_secret="fallback_${DEPLOYMENT_ID}_$RANDOM"
    fi

    umask 077
    {
        echo "# Auto-generated environment file"
        echo "# Generated: $(date)"
        echo
        echo "SPLUNK_USER=${SPLUNK_USER}"
        if (( WRITE_PASSWORD_TO_ENV )); then
            log_message WARN "Writing SPLUNK_PASSWORD into .env (convenient but NOT recommended on shared systems)"
            echo "SPLUNK_PASSWORD=${SPLUNK_PASSWORD}"
        fi
        echo "SPLUNK_SECRET=${splunk_secret}"
        echo "CLUSTER_SECRET=${cluster_secret}"
        echo "COMPOSE_PROJECT_NAME=splunk"
    } > "$ENV_FILE"

    chmod 600 "$ENV_FILE" || true
    ENV_GENERATED=1
    log_message SUCCESS "Environment file created: $ENV_FILE"
}

# ============================= Readiness / Health =============================
poll_splunk_ready() {
    # Polls https://localhost:8089/services/server/info until it answers (200/401/403)
    local timeout_sec=${1:-600}
    local interval_sec=5
    local elapsed=0
    log_message INFO "Waiting for Splunk management API (8089) to become ready (timeout ${timeout_sec}s)..."

    while (( elapsed < timeout_sec )); do
        if command -v curl >/dev/null 2>&1; then
            local code
            code=$(curl -k -m 5 -s -o /dev/null -w "%{http_code}" -u "${SPLUNK_USER}:${SPLUNK_PASSWORD}" https://localhost:8089/services/server/info || true)
            if [[ "$code" =~ ^(200|401|403)$ ]]; then
                log_message SUCCESS "Splunk management API is responding (HTTP $code)"
                return 0
            fi
            code=$(curl -k -m 5 -s -o /dev/null -w "%{http_code}" https://localhost:8089/services/server/info || true)
            if [[ "$code" =~ ^(200|401|403)$ ]]; then
                log_message SUCCESS "Splunk management API is responding (HTTP $code)"
                return 0
            fi
        fi
        sleep "$interval_sec"
        elapsed=$((elapsed + interval_sec))
        log_message DEBUG "Waiting... (${elapsed}s/${timeout_sec}s)"
    done

    log_message WARN "Management API did not become ready within ${timeout_sec}s"
    return 1
}

run_health_checks() {
    if (( SKIP_HEALTH )); then
        log_message INFO "Skipping health checks"
        return 0
    fi

    log_message INFO "Running health checks..."
    sleep 10

    local running_count
    if out_json=$($COMPOSE "${COMPOSE_FILES[@]}" ps --status running --format json 2>/dev/null); then
        running_count=$(printf "%s" "$out_json" | grep -ci splunk || true)
    else
        # Fallback: plain text listing
        out_text=$($COMPOSE "${COMPOSE_FILES[@]}" ps 2>/dev/null || true)
        running_count=$(printf "%s" "$out_text" | grep -ciE 'splunk.*(Up|running)' || true)
    fi
    if [[ "${running_count:-0}" -gt 0 ]]; then
        log_message SUCCESS "Splunk-related containers are running (${running_count} matched)"
    else
        log_message ERROR "No running Splunk containers detected"
        $COMPOSE "${COMPOSE_FILES[@]}" ps || true
        return 1
    fi

    if command -v curl >/dev/null 2>&1 && curl -s -f -m 5 http://localhost:8000 >/dev/null 2>&1; then
        log_message SUCCESS "Splunk web interface reachable on http://localhost:8000"
    else
        log_message WARN "Splunk web interface not reachable yet (8000); continuing..."
    fi

    poll_splunk_ready 600 || log_message WARN "Proceeding without mgmt readiness confirmation"
}

# ============================= Deployment Functions ===========================
pre_deployment_checks() {
    log_message INFO "Running pre-deployment checks"
    mkdir -p "$CONFIG_DIR" || error_exit "Failed to create config dir: $CONFIG_DIR"

    if (( ! FORCE_DEPLOY )) && [[ -f "$ACTIVE_MARKER" ]]; then
        log_message WARN "Existing deployment marker detected at ${ACTIVE_MARKER}"
        if (( NON_INTERACTIVE )); then
            if (( FORCE_DEPLOY )); then
                log_message INFO "Non-interactive with --force: Proceeding despite marker"
            else
                error_exit "Non-interactive: Existing deployment detected (use --force to override)"
            fi
        else
            read -p "Continue with deployment? [y/N]: " -r ans; echo
            [[ "$ans" =~ ^[Yy]$ ]] || error_exit "Deployment cancelled by user"
        fi
    fi
    local required_gb
    case "$SIZE" in
        small)  required_gb=10;;
        medium) required_gb=20;;
        large)  required_gb=50;;
        *)      required_gb=10;;
    esac
    check_disk_space "$required_gb"
    check_port_conflicts
    log_message SUCCESS "Pre-deployment checks completed"
}

build_deploy_cmd() {
    DEPLOY_CMD=( $COMPOSE "${COMPOSE_FILES[@]}" up -d "${COMPOSE_OPTS[@]}" )
}

deploy_cluster() {
    log_message INFO "Starting deployment..."
    log_message INFO "Runtime: $RUNTIME"
    log_message INFO "Compose: $COMPOSE"
    log_message INFO "Size   : $SIZE"
    (( WITH_MONITORING )) && log_message INFO "Monitoring: enabled" || log_message INFO "Monitoring: disabled"
    [[ -n "$ENVFILE" ]] && log_message INFO "Env file: $ENVFILE"

    if (( DRY_RUN )); then
        echo
        echo "---- DRY RUN MODE ----"
        printf 'Command: %q ' "${DEPLOY_CMD[@]}"; echo
        echo "Environment:"
        echo "  COMPOSE_PROFILES=$COMPOSE_PROFILES"
        echo "  SPLUNK_USER=$SPLUNK_USER"
        echo "  SPLUNK_PASSWORD=[hidden]"
        echo "----------------------"
        return 0
    fi

    cd "$SCRIPT_DIR" || error_exit "Failed to change to script directory"

    STARTED_DEPLOY=1
    if "${DEPLOY_CMD[@]}"; then
        log_message SUCCESS "Containers started successfully"
    else
        error_exit "Deployment failed. Check logs: $LOG_FILE"
    fi

    # Persist deployment marker
    {
        echo "deployment_id=${DEPLOYMENT_ID}"
        echo "timestamp=$(date -Is)"
        echo "size=${SIZE}"
        echo "with_monitoring=${WITH_MONITORING}"
        echo "compose_files=${COMPOSE_FILES[*]}"
    } > "$ACTIVE_MARKER" || log_message WARN "Failed to write active marker: $ACTIVE_MARKER"
}

validate_container_has_splunk_cli() {
    local container_id="$1"
    if ! $RUNTIME exec "$container_id" test -f /opt/splunk/bin/splunk; then
        log_message ERROR "Splunk CLI not found in container ${container_id} (/opt/splunk/bin/splunk missing)"
        return 1
    fi
    log_message DEBUG "Splunk CLI validated in container ${container_id}"
    return 0
}

configure_index() {
    if [[ -z "$INDEX_NAME" ]]; then
        return 0
    fi

    log_message INFO "Configuring index: $INDEX_NAME"
    poll_splunk_ready 600 || log_message WARN "Proceeding to index creation without confirmed readiness"

    # Service patterns: Prefer 'cm' (cluster master), fall back to 'indexer' or 'indexer-*'
    local preferred_services=("cm" "indexer")
    local service=""
    for svc_pattern in "${preferred_services[@]}"; do
        mapfile -t matching_services < <($COMPOSE "${COMPOSE_FILES[@]}" ps --services | grep -E "^${svc_pattern}(-[0-9]+)?$" || true)
        if ((${#matching_services[@]} > 0)); then
            service="${matching_services[0]}"  # Pick the first match
            log_message INFO "Selected service for index config: $service (pattern: $svc_pattern)"
            break
        fi
    done

    if [[ -z "$service" ]]; then
        log_message WARN "No matching indexer/cm service found; skipping index creation"
        return 0
    fi

    # Get running containers for the selected service (supports scaled services)
    mapfile -t containers < <($COMPOSE "${COMPOSE_FILES[@]}" ps -q "$service" | sed '/^$/d')
    local count="${#containers[@]}"
    if (( count == 0 )); then
        log_message ERROR "No running container found for service '$service'"
        return 1
    fi
    local container_id="${containers[0]}"  # Pick the first one; assume clustering handles replication
    if (( count > 1 )); then
        log_message WARN "Multiple containers (${count}) for service '$service'; using first (${container_id}) for index creation"
    fi

    # Validate Splunk CLI in container
    validate_container_has_splunk_cli "$container_id" || return 1

    # Check if index already exists
    local existing_indexes
    existing_indexes=$($RUNTIME exec "$container_id" /opt/splunk/bin/splunk list index -auth "$SPLUNK_USER:$SPLUNK_PASSWORD" 2>/dev/null || true)
    if grep -q "^${INDEX_NAME}$" <<<"$existing_indexes"; then
        log_message INFO "Index '${INDEX_NAME}' already exists; skipping creation"
        return 0
    fi

    if $RUNTIME exec "$container_id" /opt/splunk/bin/splunk add index "$INDEX_NAME" -auth "$SPLUNK_USER:$SPLUNK_PASSWORD"; then
        log_message SUCCESS "Index '${INDEX_NAME}' created"
    else
        log_message WARN "Failed to create index '${INDEX_NAME}'"
    fi
}

# ============================= Display / Summary ===============================
display_summary() {
    echo
    log_message SUCCESS "=================================================="
    log_message SUCCESS "Easy_Splunk deployment completed!"
    log_message SUCCESS "=================================================="
    echo
    echo "Deployment Summary:"
    echo "  Size       : $SIZE"
    echo "  Monitoring : $([[ $WITH_MONITORING -eq 1 ]] && echo "enabled" || echo "disabled")"
    [[ -n "$INDEX_NAME" ]] && echo "  Index      : $INDEX_NAME"
    echo
    echo "Access URLs:"
    echo "  Splunk Web : http://localhost:8000"
    echo "  Username   : $SPLUNK_USER"
    echo "  Password   : [hidden]"
    if (( WITH_MONITORING )); then
        echo "  Prometheus : http://localhost:9090"
        echo "  Grafana    : http://localhost:3000"
    fi
    echo
    echo "Useful Commands:"
    echo "  View logs       : $COMPOSE ${COMPOSE_FILES[*]} logs -f"
    echo "  Stop cluster    : $COMPOSE ${COMPOSE_FILES[*]} down"
    echo "  Container status: $COMPOSE ${COMPOSE_FILES[*]} ps"
    echo
    echo "Deployment log: $LOG_FILE"
    echo "Active marker : $ACTIVE_MARKER"
}

# ============================= Main ===========================================
main() {
    # Log everything to file and console
    exec > >(tee -a "$LOG_FILE")
    exec 2> >(tee -a "$LOG_FILE" >&2)

    log_message INFO "Starting Easy_Splunk deployment (ID: $DEPLOYMENT_ID)"

    parse_arguments "$@"
    detect_runtime
    verify_runtime
    detect_compose

    pre_deployment_checks
    build_compose_command
    validate_compose_services
    handle_credentials
    create_env_file
    build_deploy_cmd

    deploy_cluster
    configure_index
    run_health_checks
    display_summary

    log_message SUCCESS "Deployment completed successfully!"
}

main "$@"
```# Source error handling module
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Cannot load error handling module from lib/error-handling.sh" >&2
    exit 1
}

# Initialize error handling
init_error_handling

# Fallback enhanced_installation_error function for error handling library compatibility
if ! type enhanced_installation_error &>/dev/null; then
  enhanced_installation_error() {
    local error_type="$1"
    local context="$2"
    local message="$3"
    
    log_message ERROR "$message"
    log_message INFO "Error Type: $error_type"
    log_message INFO "Context: $context"
    log_message INFO "Troubleshooting steps:"
    
    case "$error_type" in
      "container-runtime")
        log_message INFO "1. Check if container runtime is installed: docker --version"
        log_message INFO "2. Verify user permissions: groups \$USER"
        log_message INFO "3. Try restarting the service: sudo systemctl restart docker"
        log_message INFO "4. Check service status: sudo systemctl status docker"
        ;;
      "compose-failure")
        log_message INFO "1. Try: docker-compose --version"
        log_message INFO "2. Try: docker compose --version"
        log_message INFO "3. Check compose file syntax: docker-compose config"
        log_message INFO "4. Verify images are available: docker images"
        ;;
      "deployment-failure")
        log_message INFO "1. Check container logs: docker-compose logs"
        log_message INFO "2. Verify resource availability: docker system info"
        log_message INFO "3. Check port conflicts: netstat -tulpn"
        log_message INFO "4. Review compose file: cat docker-compose.yml"
        ;;
      *)
        log_message INFO "1. Check system logs for more details"
        log_message INFO "2. Verify all prerequisites are installed"
        log_message INFO "3. Try running with --debug for more output"
        log_message INFO "4. Logs available at: /tmp/easy_splunk_*.log"
        ;;
    esac
    
    return 1
  }
fi

# Define with_retry function (fallback if not loaded from error-handling.sh)
if ! type with_retry &>/dev/null; then
  with_retry() {
    local retries=3 base_delay=1 max_delay=30
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --retries) retries="$2"; shift 2;;
        --base-delay) base_delay="$2"; shift 2;;
        --max-delay) max_delay="$2"; shift 2;;
        --) shift; break;;
        *) break;;
      esac
    done
    local attempt=1 delay="$base_delay"
    local cmd=("$@")
    [[ ${#cmd[@]} -gt 0 ]] || { echo "with_retry: no command provided" >&2; return 2; }
    while true; do
      "${cmd[@]}" && return 0
      local rc=$?
      if (( attempt >= retries )); then
        log_message ERROR "Command failed after $retries attempts: ${cmd[*]}"
        return $rc
      fi
      log_message WARN "Attempt $attempt failed (exit code $rc), retrying in ${delay}s..."
      sleep "$delay"
      ((attempt++))
      [[ $delay -lt $max_delay ]] && delay=$((delay * 2))
    done
  }
fi

# Fallback validate_commands function for error handling library compatibility
if ! type validate_commands &>/dev/null; then
  validate_commands() {
    for cmd in "$@"; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
        log_message ERROR "Required command not found: $cmd"
        log_message INFO "Please install $cmd and try again"
        return 1
      fi
    done
    log_message DEBUG "All required commands are available: $*"
    return 0
  }
fi

# Fallback validate_container_runtime function for error handling library compatibility
if ! type validate_container_runtime &>/dev/null; then
  validate_container_runtime() {
    local runtime="${1:-}"
    
    # If no runtime specified, try to detect available runtime
    if [[ -z "$runtime" ]]; then
      if command -v docker &>/dev/null; then
        runtime="docker"
      elif command -v podman &>/dev/null; then
        runtime="podman"
      else
        log_message ERROR "No container runtime found (docker or podman)"
        return 1
      fi
    fi
    
    log_message INFO "Validating container runtime: $runtime"
    
    if ! command -v "$runtime" &>/dev/null; then
      log_message ERROR "Container runtime not found: $runtime"
      log_message INFO "Please install $runtime and try again"
      return 1
    fi
    
    # Test if the runtime is working
    if ! "$runtime" --version &>/dev/null; then
      log_message ERROR "Container runtime not working: $runtime"
      return 1
    fi
    
    log_message INFO "Container runtime validated: $runtime"
    return 0
  }
fi

# Fallback validate_input function for error handling library compatibility
if ! type validate_input &>/dev/null; then
  validate_input() {
    local value="$1"
    local pattern="${2:-.*}"
    local description="${3:-input}"
    
    # Basic validation using pattern matching
    if [[ ! "$value" =~ $pattern ]]; then
      log_message ERROR "Invalid $description: $value"
      log_message INFO "Expected pattern: $pattern"
      return 1
    fi
    
    log_message DEBUG "Input validation passed for $description: $value"
    return 0
  }
fi

# Fallback check_disk_space function for error handling library compatibility
if ! type check_disk_space &>/dev/null; then
  check_disk_space() {
    local path="${1:-/}"
    local required_mb="${2:-1024}"
    
    log_message INFO "Checking disk space for path: $path (required: ${required_mb}MB)"
    
    if ! command -v df &>/dev/null; then
      log_message WARNING "df command not available, skipping disk space check"
      return 0
    fi
    
    # Get available space in MB
    local available_mb
    available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    
    if [[ -z "$available_mb" ]] || [[ ! "$available_mb" =~ ^[0-9]+$ ]]; then
      log_message WARNING "Could not determine disk space for $path, skipping check"
      return 0
    fi
    
    if [[ $available_mb -lt $required_mb ]]; then
      log_message ERROR "Insufficient disk space: ${available_mb}MB available, ${required_mb}MB required"
      log_message INFO "Please free up disk space and try again"
      return 1
    fi
    
    log_message INFO "Disk space check passed: ${available_mb}MB available"
    return 0
  }
fi

# Fallback validate_network function for error handling library compatibility
if ! type validate_network &>/dev/null; then
  validate_network() {
    local host="${1:-google.com}"
    local port="${2:-80}"
    local timeout="${3:-5}"
    
    log_message INFO "Checking network connectivity to $host:$port (timeout: ${timeout}s)"
    
    if command -v nc &>/dev/null; then
      if nc -z -w"$timeout" "$host" "$port" 2>/dev/null; then
        log_message INFO "Network connectivity check passed: $host:$port"
        return 0
      fi
    elif command -v telnet &>/dev/null; then
      if timeout "$timeout" telnet "$host" "$port" </dev/null 2>/dev/null | grep -q "Connected"; then
        log_message INFO "Network connectivity check passed: $host:$port"
        return 0
      fi
    elif command -v wget &>/dev/null; then
      if wget --spider --timeout="$timeout" "http://$host:$port" 2>/dev/null; then
        log_message INFO "Network connectivity check passed: $host:$port"
        return 0
      fi
    elif command -v curl &>/dev/null; then
      if curl -s --connect-timeout "$timeout" "http://$host:$port" >/dev/null 2>&1; then
        log_message INFO "Network connectivity check passed: $host:$port"
        return 0
      fi
    fi
    
    log_message WARNING "Network connectivity check failed: $host:$port"
    return 1
  }
fi

# Fallback validate_path function for error handling library compatibility
if ! type validate_path &>/dev/null; then
  validate_path() {
    local path="$1"
    local description="${2:-path}"
    
    if [[ -z "$path" ]]; then
      log_message ERROR "Empty $description provided"
      return 1
    fi
    
    # Check for invalid characters or patterns
    if [[ "$path" =~ [[:space:]] ]]; then
      log_message ERROR "Invalid $description contains spaces: $path"
      return 1
    fi
    
    if [[ "$path" =~ \.\. ]]; then
      log_message ERROR "Invalid $description contains '..': $path"
      return 1
    fi
    
    log_message DEBUG "Path validation passed: $path"
    return 0
  }
fi

# Fallback validate_cluster_config function for error handling library compatibility
if ! type validate_cluster_config &>/dev/null; then
  validate_cluster_config() {
    log_message INFO "Validating cluster configuration"
    
    # Check required environment variables
    local required_vars=("CLUSTER_NAME" "INDEXER_COUNT" "SEARCH_HEAD_COUNT")
    for var in "${required_vars[@]}"; do
      if [[ -z "${!var:-}" ]]; then
        log_message WARNING "Configuration variable $var is not set or empty"
      else
        log_message DEBUG "$var=${!var}"
      fi
    done
    
    # Validate numeric values
    if [[ -n "${INDEXER_COUNT:-}" ]] && [[ ! "${INDEXER_COUNT}" =~ ^[0-9]+$ ]]; then
      log_message ERROR "INDEXER_COUNT must be a number: ${INDEXER_COUNT}"
      return 1
    fi
    
    if [[ -n "${SEARCH_HEAD_COUNT:-}" ]] && [[ ! "${SEARCH_HEAD_COUNT}" =~ ^[0-9]+$ ]]; then
      log_message ERROR "SEARCH_HEAD_COUNT must be a number: ${SEARCH_HEAD_COUNT}"
      return 1
    fi
    
    # Validate resource constraints if set
    if [[ -n "${CPU_INDEXER:-}" ]] && [[ ! "${CPU_INDEXER}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
      log_message ERROR "CPU_INDEXER must be a number: ${CPU_INDEXER}"
      return 1
    fi
    
    if [[ -n "${MEMORY_INDEXER:-}" ]] && [[ ! "${MEMORY_INDEXER}" =~ ^[0-9]+[MGmg]?$ ]]; then
      log_message ERROR "MEMORY_INDEXER must be a valid memory specification: ${MEMORY_INDEXER}"
      return 1
    fi
    
    log_message INFO "Cluster configuration validation completed"
    return 0
  }
fi

# Fallback validate_resource_allocation function for error handling library compatibility
if ! type validate_resource_allocation &>/dev/null; then
  validate_resource_allocation() {
    log_message INFO "Validating resource allocation"
    
    # Check system resources if possible
    if command -v free &>/dev/null; then
      local total_mem_mb
      total_mem_mb=$(free -m | awk '/^Mem:/ {print $2}')
      if [[ -n "$total_mem_mb" && "$total_mem_mb" =~ ^[0-9]+$ ]]; then
        log_message INFO "System total memory: ${total_mem_mb}MB"
        
        # Warning if less than 4GB total memory
        if [[ $total_mem_mb -lt 4096 ]]; then
          log_message WARNING "Low system memory detected (${total_mem_mb}MB). Splunk cluster may require more memory."
        fi
      fi
    fi
    
    # Check CPU cores if possible
    if command -v nproc &>/dev/null; then
      local cpu_cores
      cpu_cores=$(nproc)
      if [[ -n "$cpu_cores" && "$cpu_cores" =~ ^[0-9]+$ ]]; then
        log_message INFO "System CPU cores: $cpu_cores"
        
        # Warning if less than 2 cores
        if [[ $cpu_cores -lt 2 ]]; then
          log_message WARNING "Low CPU core count detected ($cpu_cores). Splunk cluster may require more CPU resources."
        fi
      fi
    fi
    
    # Validate configured resource limits
    local total_cpu_requested=0
    local total_memory_requested=0
    
    # Calculate total requested resources based on cluster configuration
    if [[ -n "${INDEXER_COUNT:-}" ]] && [[ "${INDEXER_COUNT}" =~ ^[0-9]+$ ]]; then
      if [[ -n "${CPU_INDEXER:-}" ]] && [[ "${CPU_INDEXER}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        total_cpu_requested=$(echo "$total_cpu_requested + (${INDEXER_COUNT} * ${CPU_INDEXER})" | bc 2>/dev/null || echo "$total_cpu_requested")
      fi
    fi
    
    log_message INFO "Resource allocation validation completed"
    return 0
  }
fi

# Fallback retry_with_backoff function for error handling library compatibility
if ! type retry_with_backoff &>/dev/null; then
  retry_with_backoff() {
    local max_attempts=3
    local base_delay=1
    local max_delay=30
    
    # Parse options
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --max-attempts) max_attempts="$2"; shift 2;;
        --base-delay) base_delay="$2"; shift 2;;
        --max-delay) max_delay="$2"; shift 2;;
        --) shift; break;;
        *) break;;
      esac
    done
    
    local cmd=("$@")
    [[ ${#cmd[@]} -gt 0 ]] || { log_message ERROR "retry_with_backoff: no command provided"; return 2; }
    
    local attempt=1
    local delay="$base_delay"
    
    while [[ $attempt -le $max_attempts ]]; do
      log_message DEBUG "Attempt $attempt/$max_attempts: ${cmd[*]}"
      
      if "${cmd[@]}"; then
        log_message DEBUG "Command succeeded on attempt $attempt"
        return 0
      fi
      
      local rc=$?
      
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "Command failed after $max_attempts attempts: ${cmd[*]}"
        return $rc
      fi
      
      log_message WARNING "Attempt $attempt failed (exit code $rc), retrying in ${delay}s..."
      sleep "$delay"
      
      ((attempt++))
      # Exponential backoff with max delay cap
      delay=$((delay * 2))
      [[ $delay -gt $max_delay ]] && delay=$max_delay
    done
  }
fi

# Fallback acquire_lock function for error handling library compatibility
if ! type acquire_lock &>/dev/null; then
  acquire_lock() {
    local lock_name="${1:-deployment}"
    local timeout="${2:-30}"
    local lock_file="/tmp/easy_splunk_${lock_name}.lock"
    
    log_message INFO "Acquiring lock: $lock_name (timeout: ${timeout}s)"
    
    local count=0
    while [[ $count -lt $timeout ]]; do
      if (set -C; echo $$ > "$lock_file") 2>/dev/null; then
        log_message DEBUG "Lock acquired: $lock_file"
        # Set trap to remove lock on exit
        trap "rm -f '$lock_file'" EXIT INT TERM
        return 0
      fi
      
      log_message DEBUG "Lock unavailable, waiting... ($count/$timeout)"
      sleep 1
      ((count++))
    done
    
    log_message ERROR "Failed to acquire lock after ${timeout}s: $lock_name"
    return 1
  }
fi

# Source compose generator after core libs are loaded
# Set environment defaults for compose generation
: "${ENABLE_SPLUNK:=true}"   # Default to true for Easy_Splunk toolkit
export ENABLE_SPLUNK

if [[ -f "${SCRIPT_DIR}/lib/compose-generator.sh" ]]; then
    # shellcheck source=lib/compose-generator.sh
    source "${SCRIPT_DIR}/lib/compose-generator.sh" || {
        log_error "Cannot load compose generator from lib/compose-generator.sh"
        exit 1
    }
else
    log_warn "compose-generator.sh not found; will skip compose generation"
fi

# Configuration
readonly DEFAULT_CLUSTER_SIZE="medium"
readonly DEFAULT_SPLUNK_USER="admin"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"
readonly TEMPLATES_DIR="${SCRIPT_DIR}/config-templates"
readonly SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
readonly CREDS_DIR="${SCRIPT_DIR}/credentials"
readonly MIN_PASSWORD_LENGTH=8
readonly MAX_INDEX_NAME_LENGTH=64

# Global variables
CLUSTER_SIZE=""
CONFIG_FILE=""
INDEX_NAME=""
SPLUNK_USER="${DEFAULT_SPLUNK_USER}"
SPLUNK_PASSWORD=""
SKIP_CREDS=false
SKIP_HEALTH=false
NO_MONITORING=false
FORCE_DEPLOY=false
DEPLOYMENT_ID="$(date +%Y%m%d_%H%M%S)"

# Reserved index names that cannot be used
readonly RESERVED_INDEXES=("_audit" "_internal" "_introspection" "main" "history" "summary")

# Cleanup function for deployment
cleanup_deployment() {
    log_message INFO "Cleaning up deployment resources..."
    
    # Stop containers if deployment failed
    if [[ -f "${CONFIG_DIR}/active.conf" ]]; then
        log_message INFO "Stopping containers..."
        "${SCRIPT_DIR}/orchestrator.sh" --teardown 2>&1 | while read line; do
            log_message DEBUG "$line"
        done
    fi
    
    # Remove temporary files
    rm -f "${CONFIG_DIR}/.deploy.lock" 2>/dev/null
    rm -f "/tmp/deploy_${DEPLOYMENT_ID}.tmp" 2>/dev/null
}

# Usage function
usage() {
    cat << EOF
Usage: $0 <size|config> [options]

You can also pass a config via --config <file>.

Deploy a containerized Splunk cluster with optional monitoring.

Arguments:
    size            Cluster size: small, medium, or large
    config          Path to custom configuration file

Options:
    --config FILE          Use the specified configuration file (alternative to positional)
    --index-name NAME       Create and configure the specified index
    --splunk-user USER      Splunk admin username (default: admin)
    --splunk-password PASS  Splunk admin password (will prompt if not provided)
    --with-monitoring       Enable Prometheus and Grafana (default)
    --no-monitoring         Disable Prometheus and Grafana
    --skip-creds           Skip credential generation
    --skip-health          Skip post-deployment health check
    --force                Force deployment even if cluster exists
    --mode MODE            Optional test mode flag (ignored; accepted for CI compatibility)
    --debug                Enable debug output
    --help                 Display this help message

Examples:
    $0 medium --index-name prod_data
    $0 large --no-monitoring --splunk-user splunkadmin
    $0 ./custom.conf --skip-creds

EOF
    exit 0
}

# Validate index name
validate_index_name() {
    local index="$1"
    
    # Check length
    if [[ ${#index} -gt $MAX_INDEX_NAME_LENGTH ]]; then
        error_exit "Index name too long (max $MAX_INDEX_NAME_LENGTH characters): $index"
    fi
    
    # Check format
    if ! [[ "$index" =~ ^[a-zA-Z][a-zA-Z0-9_]*$ ]]; then
        error_exit "Index name must start with a letter and contain only alphanumeric characters and underscores: $index"
    fi
    
    # Check for reserved names
    for reserved in "${RESERVED_INDEXES[@]}"; do
        if [[ "$index" == "$reserved" ]]; then
            error_exit "Cannot use reserved index name: $index"
        fi
    done
    
    log_message DEBUG "Index name validated: $index"
}

# Parse command line arguments
parse_arguments() {
    log_message INFO "Parsing command line arguments"
    
    # Check for minimum arguments
    if [[ $# -eq 0 ]]; then
        usage
    fi
    
    # Allow --config as first arg, or a positional size/config
    case "${1:-}" in
        --config)
            CONFIG_FILE="${2:?Missing path after --config}"
            CLUSTER_SIZE="custom"
            validate_safe_path "$CONFIG_FILE" "$SCRIPT_DIR"
            shift 2
            ;;
        small|medium|large)
            CLUSTER_SIZE="$1"
            CONFIG_FILE="${TEMPLATES_DIR}/${1}-production.conf"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            if [[ -n "${1:-}" && -f "$1" ]]; then
                CONFIG_FILE="$1"
                CLUSTER_SIZE="custom"
                validate_safe_path "$CONFIG_FILE" "$SCRIPT_DIR"
                shift
            else
                error_exit "Invalid cluster size or config file: ${1:-<none>}"
            fi
            ;;
    esac
    
    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --config)
                CONFIG_FILE="$2"; validate_safe_path "$CONFIG_FILE" "$SCRIPT_DIR"; shift 2 ;;
            --config-file)
                # legacy alias used in older tests
                CONFIG_FILE="$2"; validate_safe_path "$CONFIG_FILE" "$SCRIPT_DIR"; shift 2 ;;
            --index-name)
                INDEX_NAME="$2"
                validate_index_name "$INDEX_NAME"
                shift 2
                ;;
            --splunk-user)
                SPLUNK_USER="$2"
                validate_input "$SPLUNK_USER" "^[a-zA-Z][a-zA-Z0-9_-]*$" \
                    "Username must start with a letter and contain only alphanumeric characters, hyphens, and underscores"
                shift 2
                ;;
            --splunk-password)
                SPLUNK_PASSWORD="$2"
                shift 2
                ;;
            --no-monitoring)
                NO_MONITORING=true
                shift
                ;;
            --with-monitoring)
                ENABLE_MONITORING=true
                NO_MONITORING=false
                shift
                ;;
            --skip-creds)
                SKIP_CREDS=true
                shift
                ;;
            --skip-health)
                SKIP_HEALTH=true
                shift
                ;;
            --force)
                FORCE_DEPLOY=true
                shift
                ;;
            --mode)
                # accepted for CI compatibility; no-op here
                shift 2
                ;;
            --skip-digests)
                # legacy flag; digests are resolved elsewhere; ignore safely
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                export DEBUG=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
    
    log_message INFO "Configuration: size=$CLUSTER_SIZE, config=$CONFIG_FILE"
}

# Validate environment
validate_environment() {
    log_message INFO "Validating deployment environment"
    
    # Check required commands
    validate_commands bash grep sed awk
    
    # Validate container runtime (auto-detect if available)
    if command -v docker &>/dev/null; then
        validate_container_runtime docker
    elif command -v podman &>/dev/null; then
        validate_container_runtime podman
    else
        log_message ERROR "No container runtime found (docker or podman)"
        log_message INFO "Please install docker or podman and try again"
        return 1
    fi
    
    # Check disk space (require at least 10GB)
    check_disk_space "/" 10240
    
    # Validate network connectivity
    if [[ "${SKIP_NETWORK_CHECK:-false}" != "true" ]]; then
        validate_network "hub.docker.com" 443 10 || \
            log_message WARNING "Cannot reach Docker Hub, deployment may fail if images are not cached"
    fi
    
    # Check for existing deployment
    if [[ "$FORCE_DEPLOY" != "true" ]]; then
        if [[ -f "${CONFIG_DIR}/active.conf" ]]; then
            log_message WARNING "Existing deployment detected"
            read -p "A cluster appears to be already deployed. Continue? (y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_message INFO "Deployment cancelled by user"
                exit 0
            fi
        fi
    fi
    
    # Validate configuration file
    validate_path "$CONFIG_FILE" "file"
    
    # Create necessary directories if they don't exist
    mkdir -p "$CONFIG_DIR" || error_exit "Failed to create config directory"
    mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory"
    
    # Check required directories exist after creation
    for dir in "$CONFIG_DIR" "$SCRIPTS_DIR"; do
        validate_path "$dir" "directory"
    done
    
    log_message SUCCESS "Environment validation completed"
}

# Load and validate configuration
load_configuration() {
    log_message INFO "Loading configuration from $CONFIG_FILE"
    
    # Source configuration file with error handling
    if ! source "$CONFIG_FILE"; then
        error_exit "Failed to load configuration file: $CONFIG_FILE"
    fi
    
    # Validate required configuration parameters
    local required_vars=(
        "INDEXER_COUNT"
        "SEARCH_HEAD_COUNT"
        "CPU_INDEXER"
        "MEMORY_INDEXER"
        "CPU_SEARCH_HEAD"
        "MEMORY_SEARCH_HEAD"
    )
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            error_exit "Missing required configuration parameter: $var"
        fi
    done
    
    # Validate numeric values and ranges
    validate_cluster_config "$INDEXER_COUNT" "$SEARCH_HEAD_COUNT"
    
    # Validate resource allocations
    validate_resource_allocation "$CPU_INDEXER" "$MEMORY_INDEXER"
    validate_resource_allocation "$CPU_SEARCH_HEAD" "$MEMORY_SEARCH_HEAD"
    
    # Override monitoring if specified
    if [[ "$NO_MONITORING" == "true" ]]; then
        export ENABLE_MONITORING=false
    fi
    
    # Copy configuration to active with error handling
    if ! cp "$CONFIG_FILE" "${CONFIG_DIR}/active.conf"; then
        error_exit "Failed to copy configuration to active.conf"
    fi
    
    # Set proper permissions
    chmod 644 "${CONFIG_DIR}/active.conf" || \
        log_message WARNING "Could not set permissions on active.conf"
    
    log_message SUCCESS "Configuration loaded and validated"
}

# Generate docker-compose.yml from current environment/config
generate_compose() {
    if declare -F generate_compose_file >/dev/null 2>&1; then
        log_message INFO "Generating docker-compose.yml from configuration"
        # Ensure ENABLE_SPLUNK and ENABLE_MONITORING are exported if set
        : "${ENABLE_SPLUNK:=true}"
        : "${ENABLE_MONITORING:=${NO_MONITORING:+false}}"
        export ENABLE_SPLUNK ENABLE_MONITORING
        # Compose generator relies on versions.env and various envs loaded via config
        generate_compose_file "${SCRIPT_DIR}/docker-compose.yml" || \
            error_exit "Failed to generate docker-compose.yml"
        chmod 600 "${SCRIPT_DIR}/docker-compose.yml" || true
        
        # Create .env file with required environment variables
        create_env_file
        
        log_message SUCCESS "Compose file generated"
    else
        log_message WARNING "Compose generator not available; assuming docker-compose.yml exists"
    fi
}

# Optionally generate monitoring configs if monitoring is enabled
prepare_monitoring_configs() {
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "${NO_MONITORING}" != "true" ]]; then
        local gen_mc="${SCRIPT_DIR}/generate-monitoring-config.sh"
        if [[ -x "$gen_mc" ]]; then
            log_message INFO "Generating monitoring configs"
            "$gen_mc" --yes --splunk-indexers "${INDEXER_COUNT}" --splunk-search-heads "${SEARCH_HEAD_COUNT}" || \
                log_message WARNING "Monitoring config generation reported issues"
        else
            log_message WARNING "generate-monitoring-config.sh not found or not executable"
        fi
    fi
}

# Generate or validate credentials
handle_credentials() {
    local secrets_cli="$SCRIPT_DIR/security/secrets_manager.sh"

    if [[ "$SKIP_CREDS" == "true" ]]; then
        log_message INFO "Skipping credential generation (--skip-creds specified)"
        log_message DEBUG "Current SPLUNK_PASSWORD value: [${SPLUNK_PASSWORD:-<unset>}]"

        # Use provided password if available
        if [[ -n "$SPLUNK_PASSWORD" ]]; then
            log_message INFO "Using provided SPLUNK_PASSWORD"
        else
            log_message DEBUG "SPLUNK_PASSWORD is empty, trying alternative sources"
            # Try retrieving from secrets manager
            if [[ -x "$secrets_cli" ]]; then
                if ! SPLUNK_PASSWORD=$("$secrets_cli" retrieve_credential splunk "$SPLUNK_USER" 2>/dev/null); then
                    log_message WARN "Could not retrieve password from secrets manager"
                    SPLUNK_PASSWORD=""
                fi
            fi
            
            # Try reading from credentials file if still no password
            if [[ -z "$SPLUNK_PASSWORD" ]] && [[ -f "${CREDS_DIR}/splunk_admin_password" ]]; then
                if ! SPLUNK_PASSWORD=$(cat "${CREDS_DIR}/splunk_admin_password" 2>/dev/null); then
                    log_message WARN "Failed to read existing password file"
                    SPLUNK_PASSWORD=""
                fi
            fi
            
            # Final check - if still no password, error out
            if [[ -z "$SPLUNK_PASSWORD" ]]; then
                error_exit "No password available. Cannot skip credential generation. Provide SPLUNK_PASSWORD or run without --skip-creds."
            fi
        fi
    else
        log_message INFO "Generating credentials"

        # Create credentials directory if it doesn't exist
        mkdir -p "$CREDS_DIR" || error_exit "Failed to create credentials directory"

        # Get password if not provided
        if [[ -z "$SPLUNK_PASSWORD" ]]; then
            echo
            log_message INFO "Password Requirements:"
            log_message INFO "- Minimum $MIN_PASSWORD_LENGTH characters"
            log_message INFO "- Must contain uppercase and lowercase letters"
            log_message INFO "- Must contain numbers"
            log_message INFO "- Must contain special characters"
            log_message INFO "- Cannot contain username"
            echo
            
            while true; do
                read -s -p "Enter Splunk admin password: " SPLUNK_PASSWORD
                echo
                read -s -p "Confirm password: " SPLUNK_PASSWORD_CONFIRM
                echo

                if [[ "$SPLUNK_PASSWORD" != "$SPLUNK_PASSWORD_CONFIRM" ]]; then
                    log_message ERROR "Passwords do not match. Please try again."
                    echo
                    continue
                fi
                
                # Validate password requirements
                local password_valid=true
                local error_messages=()
                
                # Check minimum length
                if [[ ${#SPLUNK_PASSWORD} -lt $MIN_PASSWORD_LENGTH ]]; then
                    error_messages+=("Password must be at least $MIN_PASSWORD_LENGTH characters long")
                    password_valid=false
                fi
                
                # Check for uppercase letter
                if [[ ! "$SPLUNK_PASSWORD" =~ [A-Z] ]]; then
                    error_messages+=("Password must contain at least one uppercase letter")
                    password_valid=false
                fi
                
                # Check for lowercase letter
                if [[ ! "$SPLUNK_PASSWORD" =~ [a-z] ]]; then
                    error_messages+=("Password must contain at least one lowercase letter")
                    password_valid=false
                fi
                
                # Check for number
                if [[ ! "$SPLUNK_PASSWORD" =~ [0-9] ]]; then
                    error_messages+=("Password must contain at least one number")
                    password_valid=false
                fi
                
                # Check for special character
                if [[ ! "$SPLUNK_PASSWORD" =~ [^a-zA-Z0-9] ]]; then
                    error_messages+=("Password must contain at least one special character")
                    password_valid=false
                fi
                
                # Check if password contains username
                if [[ "$SPLUNK_PASSWORD" == *"$SPLUNK_USER"* ]]; then
                    error_messages+=("Password cannot contain the username")
                    password_valid=false
                fi
                
                if [[ "$password_valid" == "true" ]]; then
                    log_message INFO "Password meets all requirements."
                    break
                else
                    echo
                    log_message ERROR "Password does not meet requirements:"
                    for error in "${error_messages[@]}"; do
                        log_message ERROR "- $error"
                    done
                    echo
                    log_message INFO "Please try again."
                    echo
                fi
            done
        fi

        # Generate credentials with retry logic
        local creds_script="${SCRIPTS_DIR}/generate-credentials.sh"
        if [[ ! -f "$creds_script" ]]; then
            creds_script="${SCRIPT_DIR}/generate-credentials.sh"
        fi

        if [[ -f "$creds_script" ]]; then
            retry_with_backoff "$creds_script" \
                --user "$SPLUNK_USER" \
                --password "$SPLUNK_PASSWORD" || \
                error_exit "Failed to generate credentials"
        else
            log_message WARNING "Credentials script not found, using basic generation"
            # Prefer storing in system keyring / secrets manager when available
            if [[ -x "$secrets_cli" ]]; then
                "$secrets_cli" store_credential splunk "$SPLUNK_USER" "$SPLUNK_PASSWORD" || \
                    error_exit "Failed to store password in secrets manager"
            else
                # Fallback: create basic credential files
                echo -n "$SPLUNK_USER" > "${CREDS_DIR}/splunk_admin_user" || \
                    error_exit "Failed to save username"
                echo -n "$SPLUNK_PASSWORD" > "${CREDS_DIR}/splunk_admin_password" || \
                    error_exit "Failed to save password"
                chmod 600 "${CREDS_DIR}/splunk_admin_user" "${CREDS_DIR}/splunk_admin_password" || \
                    error_exit "Failed to set credential permissions"
            fi
        fi
    fi
    
    # Export credentials for use by other scripts
    export SPLUNK_USER
    export SPLUNK_PASSWORD
    
    log_message SUCCESS "Credentials prepared"
}

# Create .env file with required environment variables for compose
create_env_file() {
    local env_file="${SCRIPT_DIR}/.env"
    local secrets_cli="$SCRIPT_DIR/security/secrets_manager.sh"
    
    log_message INFO "Creating .env file for Docker Compose"
    
    # Extract credentials from secrets manager or use exported variables
    local splunk_password="${SPLUNK_PASSWORD}"
    local splunk_secret=""
    local cluster_secret=""
    local indexer_discovery_secret=""
    local shc_secret=""
    
    if [[ -x "$secrets_cli" ]]; then
        # Try to get secrets from secrets manager
        splunk_secret=$(timeout 10 "$secrets_cli" retrieve_credential splunk splunk_secret 2>/dev/null || echo "")
        cluster_secret=$(timeout 10 "$secrets_cli" retrieve_credential splunk cluster_secret 2>/dev/null || echo "")
        indexer_discovery_secret=$(timeout 10 "$secrets_cli" retrieve_credential splunk indexer_discovery_secret 2>/dev/null || echo "")
        shc_secret=$(timeout 10 "$secrets_cli" retrieve_credential splunk shc_secret 2>/dev/null || echo "")
    fi
    
    # Generate default secrets if not available
    [[ -z "$splunk_secret" ]] && splunk_secret=$(openssl rand -hex 32 2>/dev/null || echo "default_splunk_secret_$(date +%s)")
    [[ -z "$cluster_secret" ]] && cluster_secret=$(openssl rand -hex 32 2>/dev/null || echo "default_cluster_secret_$(date +%s)")
    [[ -z "$indexer_discovery_secret" ]] && indexer_discovery_secret=$(openssl rand -hex 32 2>/dev/null || echo "default_indexer_discovery_secret_$(date +%s)")
    [[ -z "$shc_secret" ]] && shc_secret=$(openssl rand -hex 32 2>/dev/null || echo "default_shc_secret_$(date +%s)")
    
    # Create .env file
    cat > "$env_file" << EOF
# Auto-generated .env file for Easy_Splunk deployment
# Generated on: $(date)

# Splunk Configuration
SPLUNK_USER=${SPLUNK_USER:-admin}
SPLUNK_PASSWORD=${splunk_password}
SPLUNK_SECRET=${splunk_secret}
CLUSTER_SECRET=${cluster_secret}
INDEXER_DISCOVERY_SECRET=${indexer_discovery_secret}
SHC_SECRET=${shc_secret}
SPLUNK_HOME=/opt/splunk

# Project Configuration
COMPOSE_PROJECT_NAME=\${COMPOSE_PROJECT_NAME:-splunk}

# Monitoring Configuration
GRAFANA_ADMIN_PASSWORD=\${GRAFANA_ADMIN_PASSWORD:-admin123}

# Image Configuration (loaded from versions.env)
# These will be set by sourcing versions.env
EOF

    chmod 600 "$env_file"
    log_message SUCCESS ".env file created: $env_file"
}

# Check for port conflicts before deployment
check_port_conflicts() {
    log_message INFO "Checking for port conflicts..."
    
    local conflicts=()
    local required_ports=(8000 8089 9090 3000)
    local port_descriptions=("Splunk Web" "Splunk Management" "Prometheus" "Grafana")
    
    for i in "${!required_ports[@]}"; do
        local port="${required_ports[$i]}"
        local desc="${port_descriptions[$i]}"
        
        # Check if port is in use
        if command -v ss >/dev/null 2>&1; then
            # Use ss (modern)
            if ss -tlun | grep -q ":${port}\s"; then
                conflicts+=("${port} (${desc})")
            fi
        elif command -v netstat >/dev/null 2>&1; then
            # Use netstat (legacy)
            if netstat -tlun 2>/dev/null | grep -q ":${port}\s"; then
                conflicts+=("${port} (${desc})")
            fi
        else
            # Use lsof as fallback
            if command -v lsof >/dev/null 2>&1 && lsof -i ":${port}" >/dev/null 2>&1; then
                conflicts+=("${port} (${desc})")
            fi
        fi
    done
    
    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_message WARN "Port conflicts detected:"
        for conflict in "${conflicts[@]}"; do
            log_message WARN "  - Port ${conflict} is already in use"
        done
        
        echo ""
        log_message INFO "Port conflict resolution options:"
        log_message INFO "1. Stop conflicting services:"
        for conflict in "${conflicts[@]}"; do
            local port=$(echo "$conflict" | cut -d' ' -f1)
            log_message INFO "   sudo lsof -ti:${port} | xargs sudo kill -9"
        done
        log_message INFO "2. Use --force to deploy anyway (may cause failures)"
        log_message INFO "3. Configure alternative ports in config file"
        echo ""
        
        if [[ "$FORCE_DEPLOY" != "true" ]]; then
            echo "Continue with deployment despite port conflicts? [y/N]"
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                error_exit "Deployment cancelled due to port conflicts. Use --force to override."
            fi
        else
            log_message WARN "Proceeding with deployment despite port conflicts (--force specified)"
        fi
    else
        log_message SUCCESS "No port conflicts detected"
    fi
}

# Deploy the cluster
deploy_cluster() {
    log_message INFO "Starting cluster deployment"
    
    # Check if docker-compose.yml exists
    if [[ ! -f "${SCRIPT_DIR}/docker-compose.yml" ]]; then
        error_exit "Docker compose file not found. Run generate_compose first."
    fi
    
    # Acquire deployment lock
    acquire_lock "${CONFIG_DIR}/.deploy.lock" 60
    
    # Register cleanup function
    register_cleanup cleanup_deployment
    
    # Try orchestrator first, then fallback to direct compose
    local orchestrator_cmd=("${SCRIPT_DIR}/orchestrator.sh")
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "$NO_MONITORING" != "true" ]]; then
        orchestrator_cmd+=("--with-monitoring")
    fi
    
    if [[ "$FORCE_DEPLOY" == "true" ]]; then
        orchestrator_cmd+=("--force")
    fi
    
    # Try orchestrator first
    log_message INFO "Attempting deployment via orchestrator: ${orchestrator_cmd[*]}"
    
    if retry_network_operation "orchestrator deployment" "${orchestrator_cmd[@]}"; then
        log_message SUCCESS "Cluster deployment completed via orchestrator"
        return 0
    fi
    
    # Fallback to direct docker compose deployment
    log_message WARN "Orchestrator failed, falling back to direct compose deployment"
    
    if ! start_containers_direct; then
        enhanced_error "DEPLOYMENT_FAILED" \
            "Both orchestrator and direct compose deployment failed" \
            "$LOG_FILE" \
            "Check container runtime: \${CONTAINER_RUNTIME} --version" \
            "Verify compose command: \${COMPOSE_CMD} --version" \
            "Check resource availability: free -h && df -h" \
            "Review deployment logs: cat \${LOG_FILE}" \
            "Try manual restart: ./stop_cluster.sh && ./deploy.sh --force" \
            "Check network connectivity: ping -c 3 registry-1.docker.io"
        error_exit "Cluster deployment failed - enhanced troubleshooting steps provided above"
    fi
    
    log_message SUCCESS "Cluster deployment completed via direct compose"
}

# Direct container startup using docker compose
start_containers_direct() {
    log_message INFO "Starting containers directly with ${COMPOSE_CMD}"
    
    # Change to script directory for relative paths
    cd "${SCRIPT_DIR}" || error_exit "Failed to change to script directory"
    
    # Source .env file if it exists
    if [[ -f ".env" ]]; then
        set -a
        source .env
        set +a
        log_message INFO "Loaded .env file"
    fi
    
    # Pull images first
    log_message INFO "Pulling container images..."
    if ! ${COMPOSE_CMD} -f docker-compose.yml pull; then
        log_message WARN "Image pull failed, continuing with cached images"
    fi
    
    # Start containers
    log_message INFO "Starting containers in detached mode..."
    if ! ${COMPOSE_CMD} -f docker-compose.yml up -d; then
        log_message ERROR "Failed to start containers"
        return 1
    fi
    
    # Wait for containers to be ready
    log_message INFO "Waiting for containers to be ready..."
    local max_wait=300  # 5 minutes
    local wait_time=0
    local interval=10
    
    while [[ $wait_time -lt $max_wait ]]; do
        if ${COMPOSE_CMD} -f docker-compose.yml ps --filter "status=running" | grep -q "splunk"; then
            log_message SUCCESS "Containers are running"
            return 0
        fi
        
        sleep $interval
        wait_time=$((wait_time + interval))
        log_message INFO "Waiting for containers... (${wait_time}/${max_wait}s)"
    done
    
    log_message ERROR "Containers failed to start within ${max_wait} seconds"
    ${COMPOSE_CMD} -f docker-compose.yml ps
    ${COMPOSE_CMD} -f docker-compose.yml logs --tail=20
    return 1
}

# Configure Splunk indexes
configure_indexes() {
    if [[ -n "$INDEX_NAME" ]]; then
        log_message INFO "Configuring Splunk index: $INDEX_NAME"
        
        # Wait for Splunk to be ready
        sleep 10
        
        # Find the configuration script
        local config_script="${SCRIPTS_DIR}/generate-splunk-configs.sh"
        if [[ ! -f "$config_script" ]]; then
            config_script="${SCRIPT_DIR}/generate-splunk-configs.sh"
        fi
        
        if [[ -f "$config_script" ]]; then
            # Generate Splunk configurations with retry
            retry_with_backoff "$config_script" \
                --index-name "$INDEX_NAME" \
                --splunk-user "$SPLUNK_USER" \
                --splunk-password "$SPLUNK_PASSWORD" || \
                log_message WARNING "Failed to configure index $INDEX_NAME"
        else
            log_message WARNING "Configuration script not found, skipping index configuration"
        fi
    fi
}

# Run health checks
run_health_checks() {
    if [[ "$SKIP_HEALTH" == "true" ]]; then
        log_message INFO "Skipping health checks (--skip-health specified)"
        return 0
    fi
    
    log_message INFO "Running health checks"
    
    # Give services time to stabilize
    log_message INFO "Waiting for services to stabilize..."
    sleep 15
    
    # Find health check script
    local health_script="${SCRIPT_DIR}/health_check.sh"
    if [[ ! -f "$health_script" ]]; then
        health_script="${SCRIPTS_DIR}/health_check.sh"
    fi
    
    if [[ -f "$health_script" ]]; then
        # Run health check with timeout
        safe_execute 120 "$health_script" || {
            log_message WARNING "Some health checks failed. Please check the logs."
            log_message INFO "You can manually run: $health_script"
        }
    else
        log_message WARNING "Health check script not found"
    fi
}

# Display deployment summary
display_summary() {
    log_message SUCCESS "==================================================="
    log_message SUCCESS "Splunk cluster deployment completed successfully!"
    log_message SUCCESS "==================================================="
    
    echo -e "\n${GREEN}Deployment Summary:${NC}"
    echo "  Cluster Size: $CLUSTER_SIZE"
    echo "  Indexers: ${INDEXER_COUNT}"
    echo "  Search Heads: ${SEARCH_HEAD_COUNT}"
    
    if [[ -n "$INDEX_NAME" ]]; then
        echo "  Index Created: $INDEX_NAME"
    fi
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "$NO_MONITORING" != "true" ]]; then
        echo "  Monitoring: Enabled"
    fi
    
    echo -e "\n${GREEN}Access Information:${NC}"
    echo "  Splunk Web UI: http://localhost:8000"
    echo "  Username: $SPLUNK_USER"
    echo "  Password: [hidden]"
    
    if [[ "${ENABLE_MONITORING:-true}" == "true" ]] && [[ "$NO_MONITORING" != "true" ]]; then
        echo "  Prometheus: http://localhost:9090"
        echo "  Grafana: http://localhost:3000"
    fi
    
    echo -e "\n${GREEN}Useful Commands:${NC}"
    echo "  View logs: ${CONTAINER_RUNTIME} compose logs -f"
    echo "  Stop cluster: ${SCRIPT_DIR}/orchestrator.sh --teardown"
    echo "  Health check: ${SCRIPT_DIR}/health_check.sh"
    
    echo -e "\nDeployment log: $LOG_FILE"
}

# Progress tracking for deployment
DEPLOYMENT_PROGRESS=0
TOTAL_DEPLOYMENT_STEPS=8

show_deployment_progress() {
    local current=$1
    local total=$2
    local description=$3
    local percent=$((current * 100 / total))
    local filled=$((current * 25 / total))
    local empty=$((25 - filled))
    
    printf "\r🚀 [%s%s] %d%% - %s" \
        "$(printf "%0.s█" $(seq 1 $filled))" \
        "$(printf "%0.s░" $(seq 1 $empty))" \
        "$percent" \
        "$description"
    
    if [[ $current -eq $total ]]; then
        echo ""
        echo ""
    fi
}

update_deployment_progress() {
    ((DEPLOYMENT_PROGRESS++))
    show_deployment_progress $DEPLOYMENT_PROGRESS $TOTAL_DEPLOYMENT_STEPS "$1"
    sleep 0.5  # Brief pause for visual effect
}

# Main execution
main() {
    log_message INFO "Starting Easy_Splunk deployment script"
    echo ""
    log_message INFO "🎯 Deployment will complete $TOTAL_DEPLOYMENT_STEPS steps"
    echo ""
    
    update_deployment_progress "Parsing command line arguments"
    
    # Parse arguments
    parse_arguments "$@"
    
    update_deployment_progress "Validating environment"
    # Validate environment
    validate_environment
    
    update_deployment_progress "Loading configuration"
    # Load configuration
    load_configuration
    
    update_deployment_progress "Handling credentials"
    # Handle credentials
    handle_credentials
    
    update_deployment_progress "Checking port conflicts"
    # Check for port conflicts
    check_port_conflicts
    
    update_deployment_progress "Generating compose file"
    # Generate compose file
    generate_compose

    update_deployment_progress "Preparing monitoring configs"
    # Prepare monitoring configs (if enabled)
    prepare_monitoring_configs

    update_deployment_progress "Starting cluster containers"
    # Deploy cluster
    deploy_cluster
    
    update_deployment_progress "Finalizing deployment"
    # Configure indexes
    configure_indexes
    
    # Run health checks
    run_health_checks
    
    # Display summary
    display_summary
    
    log_message SUCCESS "Deployment script completed successfully"
}

# Execute main function
main "$@"
    