#!/usr/bin/env bash
#
# ==============================================================================
# parse-args.sh
# Enhanced argument parsing + config templating for orchestrator.sh
#
# Dependencies: lib/core.sh (log_*, die, is_true, is_empty, is_number)
#               lib/validation.sh (validate_required_var, validate_or_prompt_for_dir)
# ==============================================================================

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1 || ! command -v validate_required_var >/dev/null 2>&1; then
  echo "FATAL: lib/core.sh and lib/validation.sh must be sourced before parse-args.sh" >&2
  exit 1
fi

# ---- Defaults (honor pre-set env; otherwise set) --------------------------------
: "${APP_PORT:=8080}"
: "${DATA_DIR:=/var/lib/my-app}"
: "${ENABLE_MONITORING:=false}"
: "${ENABLE_SPLUNK:=false}"
: "${INTERACTIVE_MODE:=false}"
: "${APP_CPU_LIMIT:=1.5}"
: "${APP_MEM_LIMIT:=2G}"
: "${NON_INTERACTIVE:=0}"        # if 1, ignore -i/--interactive
: "${OUTPUT_EFFECTIVE_CONFIG:=}" # path to write normalized config (optional)
: "${CONFIG_VALIDATION:=true}"   # validate configuration after parsing

# Splunk-specific defaults
: "${SPLUNK_CLUSTER_MODE:=single}"
: "${SPLUNK_WEB_PORT:=8000}"
: "${INDEXER_COUNT:=1}"
: "${SEARCH_HEAD_COUNT:=1}"
: "${SPLUNK_REPLICATION_FACTOR:=1}"
: "${SPLUNK_SEARCH_FACTOR:=1}"
: "${SPLUNK_DATA_DIR:=/opt/splunk-data}"
: "${SPLUNK_PASSWORD:=}"
: "${SPLUNK_SECRET:=}"

# Advanced options
: "${DRY_RUN:=false}"
: "${VERBOSE:=false}"
: "${LOG_LEVEL:=info}"
: "${COMPOSE_PROJECT_NAME:=}"

# ---- Usage ---------------------------------------------------------------------
_usage() {
  cat <<EOF
Usage: orchestrator.sh [options]

Basic Options:
  --config <file>        Load key=value defaults from a template file (POSIX .env style)
  --port <port>          Public port for the app (default: ${APP_PORT})
  --data-dir <path>      Persistent data directory (default: ${DATA_DIR})
  --project-name <name>  Docker Compose project name (default: auto-generated)
  -i, --interactive      Prompt for missing values (ignored if NON_INTERACTIVE=1)
  
Services:
  --with-monitoring      Enable Prometheus & Grafana
  --no-monitoring        Disable monitoring (overrides template/env)
  --with-splunk          Enable Splunk cluster
  --no-splunk           Disable Splunk cluster
  
Splunk Configuration:
  --splunk-mode <mode>   Cluster mode: single|cluster (default: ${SPLUNK_CLUSTER_MODE})
  --splunk-web-port <p>  Splunk Web port (default: ${SPLUNK_WEB_PORT})
  --indexers <count>     Number of indexer nodes (default: ${INDEXER_COUNT})
  --search-heads <count> Number of search head nodes (default: ${SEARCH_HEAD_COUNT})
  --replication-factor <rf> Splunk replication factor (default: ${SPLUNK_REPLICATION_FACTOR})
  --search-factor <sf>   Splunk search factor (default: ${SPLUNK_SEARCH_FACTOR})
  --splunk-data-dir <dir> Splunk data directory (default: ${SPLUNK_DATA_DIR})
  --splunk-password <pwd> Splunk admin password (prompt if not provided)
  --splunk-secret <key>  Splunk secret key (auto-generate if not provided)
  
Resource Management:
  --app-cpu <limit>      CPU limit for app (e.g., 1.5)
  --app-mem <limit>      Memory limit for app (e.g., 2G)
  
Advanced Options:
  --dry-run             Show what would be done without executing
  --verbose             Enable verbose logging
  --log-level <level>   Set log level: debug|info|warn|error (default: ${LOG_LEVEL})
  --no-validation       Skip configuration validation
  --write-effective <f> Write normalized config (key=value) to file <f>
  
  -h, --help            Show this help and exit

Configuration Precedence:
  defaults < --config file < environment variables < CLI flags

Examples:
  # Basic application deployment
  $(basename "$0") --port 8080 --data-dir /opt/myapp

  # Splunk cluster with monitoring
  $(basename "$0") --with-splunk --with-monitoring --indexers 3 --search-heads 2

  # Load from template and override specific values
  $(basename "$0") --config production.env --splunk-web-port 8000

  # Interactive mode for missing configuration
  $(basename "$0") --interactive --with-splunk
EOF
}

# ---- Enhanced Helpers ----------------------------------------------------------
_load_env_file() {
  # load a .env-like file safely (KEY=VALUE pairs, allows quotes and comments)
  local f="${1:?config file required}"
  [[ -f "$f" ]] || die "${E_INVALID_INPUT}" "Configuration file not found: ${f}"
  log_info "Loading configuration from template: ${f}"

  local line_num=0
  # shellcheck disable=SC1090
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_num++))
    # trim leading/trailing whitespace
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    # skip blanks and comments
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    # only accept KEY=VALUE
    if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      local k="${BASH_REMATCH[1]}"
      local v="${BASH_REMATCH[2]}"
      # strip surrounding quotes if present
      if [[ "$v" =~ ^\"(.*)\"$ ]]; then v="${BASH_REMATCH[1]}"; fi
      if [[ "$v" =~ ^\'(.*)\'$ ]]; then v="${BASH_REMATCH[1]}"; fi
      # only set if variable is currently unset (template < env < CLI)
      if [[ -z "${!k+x}" ]]; then
        printf -v "$k" '%s' "$v"
        export "$k"
        log_debug "Loaded from config: ${k}=${v}"
      else
        log_debug "Skipped (already set): ${k}=${!k}"
      fi
    else
      log_warn "Ignoring invalid line ${line_num} in ${f}: ${line}"
    fi
  done < "$f"
}

_write_effective_config() {
  local out="${1:?output file required}"
  umask 077
  log_info "Writing effective configuration to: ${out}"
  
  cat > "${out}" <<EOF
# ==============================================================================
# Normalized configuration generated by parse-args.sh
# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# ==============================================================================

# Basic Configuration
APP_PORT=${APP_PORT}
DATA_DIR=${DATA_DIR}
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}
LOG_LEVEL=${LOG_LEVEL}

# Service Enablement
ENABLE_MONITORING=${ENABLE_MONITORING}
ENABLE_SPLUNK=${ENABLE_SPLUNK}

# Resource Limits
APP_CPU_LIMIT=${APP_CPU_LIMIT}
APP_MEM_LIMIT=${APP_MEM_LIMIT}

# Splunk Configuration
SPLUNK_CLUSTER_MODE=${SPLUNK_CLUSTER_MODE}
SPLUNK_WEB_PORT=${SPLUNK_WEB_PORT}
INDEXER_COUNT=${INDEXER_COUNT}
SEARCH_HEAD_COUNT=${SEARCH_HEAD_COUNT}
SPLUNK_REPLICATION_FACTOR=${SPLUNK_REPLICATION_FACTOR}
SPLUNK_SEARCH_FACTOR=${SPLUNK_SEARCH_FACTOR}
SPLUNK_DATA_DIR=${SPLUNK_DATA_DIR}
$(if [[ -n "${SPLUNK_PASSWORD}" ]]; then echo "SPLUNK_PASSWORD=<redacted>"; fi)
$(if [[ -n "${SPLUNK_SECRET}" ]]; then echo "SPLUNK_SECRET=<redacted>"; fi)

# Runtime Options
INTERACTIVE_MODE=${INTERACTIVE_MODE}
DRY_RUN=${DRY_RUN}
VERBOSE=${VERBOSE}
EOF
  log_success "Effective configuration written"
}

_auto_generate_splunk_secret() {
  if [[ -z "${SPLUNK_SECRET}" ]] && is_true "${ENABLE_SPLUNK}"; then
    log_info "Auto-generating Splunk secret key..."
    SPLUNK_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    export SPLUNK_SECRET
    log_debug "Splunk secret generated"
  fi
}

_auto_generate_project_name() {
  if [[ -z "${COMPOSE_PROJECT_NAME}" ]]; then
    local base_name
    base_name=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    COMPOSE_PROJECT_NAME="${base_name:-myapp}"
    export COMPOSE_PROJECT_NAME
    log_debug "Auto-generated project name: ${COMPOSE_PROJECT_NAME}"
  fi
}

_prompt_for_splunk_password() {
  if is_true "${ENABLE_SPLUNK}" && [[ -z "${SPLUNK_PASSWORD}" ]]; then
    if is_true "${INTERACTIVE_MODE}" && (( NON_INTERACTIVE == 0 )); then
      local password confirm
      while true; do
        read -r -s -p "Enter Splunk admin password: " password </dev/tty
        echo
        if [[ ${#password} -ge 8 ]]; then
          read -r -s -p "Confirm password: " confirm </dev/tty
          echo
          if [[ "$password" == "$confirm" ]]; then
            SPLUNK_PASSWORD="$password"
            export SPLUNK_PASSWORD
            break
          else
            log_warn "Passwords do not match. Please try again."
          fi
        else
          log_warn "Password must be at least 8 characters long."
        fi
      done
    else
      die "${E_INVALID_INPUT}" "Splunk password required. Set SPLUNK_PASSWORD or use --interactive mode."
    fi
  fi
}

_validate_values() {
  if ! is_true "${CONFIG_VALIDATION}"; then
    log_warn "Configuration validation disabled"
    return 0
  fi
  
  log_info "Validating configuration..."
  
  # Port sanity
  if ! is_number "${APP_PORT}" || (( APP_PORT < 1 || APP_PORT > 65535 )); then
    die "${E_INVALID_INPUT}" "Invalid --port '${APP_PORT}'. Must be 1..65535."
  fi
  
  # Splunk web port validation
  if is_true "${ENABLE_SPLUNK}"; then
    if ! is_number "${SPLUNK_WEB_PORT}" || (( SPLUNK_WEB_PORT < 1 || SPLUNK_WEB_PORT > 65535 )); then
      die "${E_INVALID_INPUT}" "Invalid Splunk web port '${SPLUNK_WEB_PORT}'. Must be 1..65535."
    fi
  fi
  
  # Cluster sizing validation
  if is_true "${ENABLE_SPLUNK}"; then
    if ! is_number "${INDEXER_COUNT}" || (( INDEXER_COUNT < 1 )); then
      die "${E_INVALID_INPUT}" "Invalid indexer count '${INDEXER_COUNT}'. Must be >= 1."
    fi
    if ! is_number "${SEARCH_HEAD_COUNT}" || (( SEARCH_HEAD_COUNT < 1 )); then
      die "${E_INVALID_INPUT}" "Invalid search head count '${SEARCH_HEAD_COUNT}'. Must be >= 1."
    fi
    
    # Use validation library for RF/SF validation
    validate_rf_sf "${SPLUNK_REPLICATION_FACTOR}" "${SPLUNK_SEARCH_FACTOR}" "${INDEXER_COUNT}"
  fi
  
  # Data directories
  if is_true "${INTERACTIVE_MODE}" && (( NON_INTERACTIVE == 0 )); then
    validate_or_prompt_for_dir "DATA_DIR" "application data"
    if is_true "${ENABLE_SPLUNK}"; then
      validate_or_prompt_for_dir "SPLUNK_DATA_DIR" "Splunk data"
    fi
  else
    validate_required_var "${DATA_DIR}" "Data Directory (--data-dir)"
    if is_true "${ENABLE_SPLUNK}"; then
      validate_required_var "${SPLUNK_DATA_DIR}" "Splunk Data Directory (--splunk-data-dir)"
    fi
  fi
  
  # Log level validation
  case "${LOG_LEVEL}" in
    debug|info|warn|error) ;;
    *) die "${E_INVALID_INPUT}" "Invalid log level '${LOG_LEVEL}'. Must be: debug, info, warn, error" ;;
  esac
  
  log_success "Configuration validation passed"
}

_show_configuration_summary() {
  log_info "=== Configuration Summary ==="
  log_info "Project: ${COMPOSE_PROJECT_NAME}"
  log_info "App Port: ${APP_PORT}"
  log_info "Data Directory: ${DATA_DIR}"
  log_info "Log Level: ${LOG_LEVEL}"
  log_info "Services:"
  log_info "  • Application: enabled"
  log_info "  • Monitoring: ${ENABLE_MONITORING}"
  log_info "  • Splunk: ${ENABLE_SPLUNK}"
  
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "Splunk Configuration:"
    log_info "  • Mode: ${SPLUNK_CLUSTER_MODE}"
    log_info "  • Web Port: ${SPLUNK_WEB_PORT}"
    log_info "  • Indexers: ${INDEXER_COUNT}"
    log_info "  • Search Heads: ${SEARCH_HEAD_COUNT}"
    log_info "  • Replication Factor: ${SPLUNK_REPLICATION_FACTOR}"
    log_info "  • Search Factor: ${SPLUNK_SEARCH_FACTOR}"
    log_info "  • Data Directory: ${SPLUNK_DATA_DIR}"
  fi
  
  if is_true "${DRY_RUN}"; then
    log_warn "DRY RUN MODE: No actual changes will be made"
  fi
}

# ---- Main ----------------------------------------------------------------------
parse_arguments() {
  local argv=("$@")

  # First pass: isolate --config to populate defaults early
  local i=0
  while (( i < ${#argv[@]} )); do
    case "${argv[$i]}" in
      --config)
        local cfg="${argv[$((i+1))]:-}"
        [[ -n "$cfg" ]] || die "${E_INVALID_INPUT}" "--config requires a file path"
        _load_env_file "$cfg"
        ((i+=2)); continue;;
      --verbose)
        VERBOSE="true"
        DEBUG="true"  # Enable debug logging for verbose mode
        ((i++)); continue;;
      *) ((i++));;
    esac
  done

  # Second pass: parse all flags (CLI overrides template/env)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) _usage; exit 0 ;;
      -i|--interactive) INTERACTIVE_MODE="true"; shift ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --verbose) VERBOSE="true"; DEBUG="true"; shift ;;
      --log-level) LOG_LEVEL="${2:?}"; shift 2 ;;
      --no-validation) CONFIG_VALIDATION="false"; shift ;;
      
      # Services
      --with-monitoring) ENABLE_MONITORING="true"; shift ;;
      --no-monitoring)   ENABLE_MONITORING="false"; shift ;;
      --with-splunk)     ENABLE_SPLUNK="true"; shift ;;
      --no-splunk)       ENABLE_SPLUNK="false"; shift ;;
      
      # Basic config
      --port)         APP_PORT="${2:?}"; shift 2 ;;
      --data-dir)     DATA_DIR="${2:?}"; shift 2 ;;
      --project-name) COMPOSE_PROJECT_NAME="${2:?}"; shift 2 ;;
      --app-cpu)      APP_CPU_LIMIT="${2:?}"; shift 2 ;;
      --app-mem)      APP_MEM_LIMIT="${2:?}"; shift 2 ;;
      
      # Splunk config
      --splunk-mode)        SPLUNK_CLUSTER_MODE="${2:?}"; shift 2 ;;
      --splunk-web-port)    SPLUNK_WEB_PORT="${2:?}"; shift 2 ;;
      --indexers)           INDEXER_COUNT="${2:?}"; shift 2 ;;
      --search-heads)       SEARCH_HEAD_COUNT="${2:?}"; shift 2 ;;
      --replication-factor) SPLUNK_REPLICATION_FACTOR="${2:?}"; shift 2 ;;
      --search-factor)      SPLUNK_SEARCH_FACTOR="${2:?}"; shift 2 ;;
      --splunk-data-dir)    SPLUNK_DATA_DIR="${2:?}"; shift 2 ;;
      --splunk-password)    SPLUNK_PASSWORD="${2:?}"; shift 2 ;;
      --splunk-secret)      SPLUNK_SECRET="${2:?}"; shift 2 ;;
      
      # Already handled
      --config) shift 2 ;;
      
      # Output
      --write-effective) OUTPUT_EFFECTIVE_CONFIG="${2:?}"; shift 2 ;;
      
      *) die "${E_INVALID_INPUT}" "Unknown option: $1. Use --help for usage." ;;
    esac
  done

  # If NON_INTERACTIVE=1 is set, force interactive off
  if (( NON_INTERACTIVE == 1 )); then
    INTERACTIVE_MODE="false"
  fi

  # Auto-generate missing values
  _auto_generate_project_name
  _auto_generate_splunk_secret
  
  # Interactive prompts for required values
  _prompt_for_splunk_password

  # Validation
  _validate_values
  
  # Show summary
  _show_configuration_summary

  # Optionally write normalized config for later stages / reproducibility
  if [[ -n "${OUTPUT_EFFECTIVE_CONFIG}" ]]; then
    _write_effective_config "${OUTPUT_EFFECTIVE_CONFIG}"
  fi

  # Export for orchestrator
  export APP_PORT DATA_DIR ENABLE_MONITORING ENABLE_SPLUNK APP_CPU_LIMIT APP_MEM_LIMIT
  export INTERACTIVE_MODE COMPOSE_PROJECT_NAME LOG_LEVEL DRY_RUN VERBOSE
  export SPLUNK_CLUSTER_MODE SPLUNK_WEB_PORT INDEXER_COUNT SEARCH_HEAD_COUNT
  export SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR SPLUNK_DATA_DIR
  export SPLUNK_PASSWORD SPLUNK_SECRET
}