#!/usr/bin/env bash
#
# ==============================================================================
# parse-args.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# Provides enhanced argument parsing for the main orchestrator script.
#
# Features:
#   - Handles long and short command-line options.
#   - Supports loading default values from a configuration "template" file.
#   - Includes an interactive mode to prompt for missing required values.
#
# Dependencies: core.sh, validation.sh
# Required by:  orchestrator.sh
#
# ==============================================================================

# --- Source Dependencies ---
# Assumes core libraries have been sourced by the orchestrator.
if [[ -z "$(type -t log_info)" || -z "$(type -t validate_required_var)" ]]; then
    echo "FATAL: lib/core.sh and lib/validation.sh must be sourced before parse-args.sh" >&2
    exit 1
fi

# --- Default Configuration Values ---
# These can be overridden by a config template or command-line arguments.
export APP_PORT="8080"
export DATA_DIR="/var/lib/my-app"
export ENABLE_MONITORING="false"
export INTERACTIVE_MODE="false"
# Resource limits
export APP_CPU_LIMIT="1.5"
export APP_MEM_LIMIT="2G"

# --- Private Helper Functions ---

_usage() {
    cat << EOF
Usage: orchestrator.sh [options]

The main entry point for deploying and managing the application stack.

Options:
  --config <file>       Load configuration from the specified template file.
  --port <port>         Set the public port for the main application. (Default: ${APP_PORT})
  --data-dir <path>     Set the path for persistent application data. (Default: ${DATA_DIR})
  --with-monitoring     Enable the Prometheus and Grafana monitoring stack. (Default: disabled)
  -i, --interactive     Enable interactive mode to prompt for required settings.
  -h, --help            Display this help message and exit.

Resource Options:
  --app-cpu <limit>     Set the CPU limit for the main app. (Default: ${APP_CPU_LIMIT})
  --app-mem <limit>     Set the memory limit for the main app. (Default: ${APP_MEM_LIMIT})

EOF
}

_load_config_template() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        die "$E_INVALID_INPUT" "Configuration file not found: ${config_file}"
    fi

    log_info "Loading configuration from template: ${config_file}"
    # Source the file to override default variables
    # The config file should contain simple VAR="value" assignments
    source "$config_file"
}

# --- Main Public Function ---

# Parses all command-line arguments, loading templates and handling flags.
# After parsing, it can enter interactive mode to fill in any missing details.
parse_arguments() {
    # First, check for a config file argument specifically, so it's loaded first.
    for i in "$@"; do
        if [[ "$i" == "--config" ]]; then
            # The argument after --config is the file path
            local config_file_path
            # This is a bit of a trick to get the next argument in the loop
            config_file_path=$(eval "echo \$$(( (i=i, i) + 1 ))")
            _load_config_template "$config_file_path"
            break
        fi
    done

    # Main argument parsing loop
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                _usage
                exit 0
                ;;
            -i|--interactive)
                INTERACTIVE_MODE="true"
                shift # past argument
                ;;
            --config)
                # We already handled this, so just skip past the flag and its value
                shift 2
                ;;
            --port)
                APP_PORT="$2"
                shift 2 # past argument and value
                ;;
            --data-dir)
                DATA_DIR="$2"
                shift 2
                ;;
            --with-monitoring)
                ENABLE_MONITORING="true"
                shift # past argument
                ;;
            --app-cpu)
                APP_CPU_LIMIT="$2"
                shift 2
                ;;
            --app-mem)
                APP_MEM_LIMIT="$2"
                shift 2
                ;;
            *)
                # Unknown option
                die "$E_INVALID_INPUT" "Unknown option: $1"
                ;;
        esac
    done

    # --- Post-Parsing Validation & Interactive Mode ---
    log_info "Configuration loaded. Final values:"
    log_info "  -> App Port: ${APP_PORT}"
    log_info "  -> Data Directory: ${DATA_DIR}"
    log_info "  -> Monitoring: ${ENABLE_MONITORING}"

    if is_true "$INTERACTIVE_MODE"; then
        log_info "Interactive mode enabled. Validating settings..."
        # Use the recovery function from validation.sh
        validate_or_prompt_for_dir "DATA_DIR" "application data"
    else
        # In non-interactive mode, just validate that required settings exist.
        validate_required_var "${DATA_DIR}" "Data Directory (--data-dir)"
    fi

    # Export all variables to make them available to the main orchestrator script
    export APP_PORT DATA_DIR ENABLE_MONITORING APP_CPU_LIMIT APP_MEM_LIMIT
}