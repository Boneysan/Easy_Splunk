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

# Load versions.env to get image references
if [[ -f "${SCRIPT_DIR}/versions.env" ]]; then
    source "${SCRIPT_DIR}/versions.env" || error_exit "Failed to load versions.env"
    log_message DEBUG "Loaded image versions from versions.env"
else
    error_exit "versions.env not found - required for image references"
fi

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
  --simple-creds             Use simple credential mode (requires SPLUNK_PASSWORD env var)
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
            --simple-creds)     SIMPLE_CREDS=true; shift;;
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
