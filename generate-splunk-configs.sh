#!/usr/bin/env bash
#
# ==============================================================================
# generate-splunk-configs.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# Automates the configuration of a Splunk instance via its REST API.
# This script creates a dedicated index and an HTTP Event Collector (HEC)
# token for the application to use for sending data.
#
# Features:
#   - API-based setup for remote Splunk management.
#   - Creates a new index for application data, following best practices.
#   - Creates and enables a HEC token for secure data ingestion.
#
# Dependencies: core.sh
# Required by:  Post-deployment configuration
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"

# --- Argument Variables ---
SPLUNK_API_HOST="localhost"
SPLUNK_API_PORT="8089"
SPLUNK_USER=""
SPLUNK_PASSWORD=""
INDEX_NAME=""

# --- Helper Functions ---

_usage() {
    cat << EOF
Usage: ./generate-splunk-configs.sh --splunk-user <user> --index-name <name> [options]

Configures a Splunk instance via its REST API.

Required Arguments:
  --splunk-user <user>      Username for the Splunk management API.
  --index-name <name>       The name of the data index to create (e.g., 'my_app_prod').

Options:
  --splunk-password <pass>  Password for the Splunk user. If not provided, you will be prompted securely.
  --splunk-api-host <host>  Hostname or IP of the Splunk API. (Default: localhost)
  --splunk-api-port <port>  Port for the Splunk API. (Default: 8089)
  -h, --help                Display this help message and exit.
EOF
}

# A wrapper for curl to handle common Splunk API call settings
_splunk_api_call() {
    local method="$1"
    local endpoint="$2"
    shift 2
    local data=("$@")

    local base_url="https://${SPLUNK_API_HOST}:${SPLUNK_API_PORT}"
    
    # The '-k' flag is often needed for Splunk instances with self-signed certs.
    curl -s -k \
        -u "${SPLUNK_USER}:${SPLUNK_PASSWORD}" \
        -X "$method" \
        "${data[@]}" \
        "${base_url}${endpoint}"
}

# --- Main Function ---

main() {
    # 1. Parse Arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --splunk-user) SPLUNK_USER="$2"; shift 2 ;;
            --splunk-password) SPLUNK_PASSWORD="$2"; shift 2 ;;
            --index-name) INDEX_NAME="$2"; shift 2 ;;
            --splunk-api-host) SPLUNK_API_HOST="$2"; shift 2 ;;
            --splunk-api-port) SPLUNK_API_PORT="$2"; shift 2 ;;
            -h|--help) _usage; exit 0 ;;
            *) die "$E_INVALID_INPUT" "Unknown option: $1" ;;
        esac
    done

    # 2. Validate Arguments and Dependencies
    if is_empty "$SPLUNK_USER" || is_empty "$INDEX_NAME"; then
        die "$E_INVALID_INPUT" "Missing required arguments. Use --help for more info."
    fi
    if is_empty "$SPLUNK_PASSWORD"; then
        read -s -r -p "Enter Splunk Password for user '${SPLUNK_USER}': " SPLUNK_PASSWORD
        echo
    fi
    if ! command -v curl &>/dev/null; then
        die "$E_MISSING_DEP" "curl is not installed but is required to use the Splunk API."
    fi

    log_info "🚀 Configuring Splunk instance at ${SPLUNK_API_HOST}..."
    log_warn "This script uses '-k' to ignore self-signed certificates, a common setup."

    # 3. Create Splunk Index
    log_info "Checking for Splunk index '${INDEX_NAME}'..."
    local index_check_response
    index_check_response=$(_splunk_api_call "GET" "/services/data/indexes/${INDEX_NAME}" -o /dev/null -w "%{http_code}")
    
    if [[ "$index_check_response" == "200" ]]; then
        log_success "  -> Index '${INDEX_NAME}' already exists."
    elif [[ "$index_check_response" == "404" ]]; then
        log_info "  -> Index does not exist. Creating it now..."
        _splunk_api_call "POST" "/services/data/indexes" -d "name=${INDEX_NAME}" > /dev/null
        log_success "  -> Index '${INDEX_NAME}' created."
    else
        die "$E_GENERAL" "Failed to check or create index. HTTP status: ${index_check_response}. Check credentials and connectivity."
    fi

    # 4. Create HEC Token
    local hec_token_name="app_${INDEX_NAME}_token"
    log_info "Checking for HEC Token '${hec_token_name}'..."
    local hec_check_response
    hec_check_response=$(_splunk_api_call "GET" "/services/data/inputs/http/${hec_token_name}" -o /dev/null -w "%{http_code}")

    if [[ "$hec_check_response" == "200" ]]; then
        log_success "  -> HEC Token '${hec_token_name}' already exists."
    elif [[ "$hec_check_response" == "404" ]]; then
        log_info "  -> HEC Token does not exist. Creating it now..."
        _splunk_api_call "POST" "/services/data/inputs/http" -d "name=${hec_token_name}" -d "index=${INDEX_NAME}" -d "disabled=0" > /dev/null
        log_success "  -> HEC Token '${hec_token_name}' created and enabled."
    else
        die "$E_GENERAL" "Failed to check or create HEC Token. HTTP status: ${hec_check_response}."
    fi

    # 5. Retrieve and display the HEC token value
    log_info "Retrieving HEC token value..."
    local token_value
    # The token is returned in a stanza entry in XML format. We can parse it with sed.
    token_value=$(_splunk_api_call "GET" "/services/data/inputs/http/${hec_token_name}?output_mode=json" | sed -n 's/.*"token": "\(.*\)"/\1/p')
    
    if is_empty "$token_value"; then
        die "$E_GENERAL" "Could not retrieve the HEC token value. Please check the Splunk UI."
    fi

    log_success "✅ Splunk configuration complete!"
    log_info "Use the following HEC token to send data to the '${INDEX_NAME}' index:"
    log_info "HEC Token: ${token_value}"
}

# --- Script Execution ---
main "$@"