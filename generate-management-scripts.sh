#!/usr/bin/env bash
#
# ==============================================================================
# generate-management-scripts.sh
# ------------------------------------------------------------------------------
# ⭐⭐
#
# Generates a suite of helper scripts for managing the application via its API.
# This script reads sensitive credentials (like an API key) and embeds them
# into simple, task-specific wrapper scripts.
#
# Features:
#   - Generates multiple, ready-to-use management scripts.
#   - Integrates with the application's API.
#   - Provides a template for creating further automation tools.
#
# Dependencies: core.sh
# Required by:  orchestrator.sh
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"

# --- Configuration ---
readonly MGMT_SCRIPTS_DIR="./management-scripts"
readonly SECRETS_ENV_FILE="./config/secrets/production.env"
readonly API_BASE_URL="http://localhost:8080/api/v1"

# This variable will be populated by sourcing the secrets file.
API_KEY=""

# --- Private Script Generators ---

_generate_get_health_script() {
    local script_path="${MGMT_SCRIPTS_DIR}/get-health.sh"
    log_info "  -> Generating: ${script_path}"
    
    # Create the script using a here-document
    cat > "$script_path" <<EOF
#!/usr/bin/env bash
# Checks the health of the application API.

echo "Querying API health endpoint..."
# The -f flag fails silently on server errors, -s is silent on progress.
curl -fs -H "Authorization: Bearer ${API_KEY}" "${API_BASE_URL}/health" | \
    (command -v jq &>/dev/null && jq . || cat) # Pretty-print with jq if available

if [[ \$? -eq 0 ]]; then
    echo "API is healthy."
else
    echo "Error connecting to API."
fi
EOF
    chmod +x "$script_path"
}

_generate_list_users_script() {
    local script_path="${MGMT_SCRIPTS_DIR}/list-users.sh"
    log_info "  -> Generating: ${script_path}"
    
    cat > "$script_path" <<EOF
#!/usr/bin/env bash
# Lists all users via the application API.

echo "Fetching user list..."
curl -fs -H "Authorization: Bearer ${API_KEY}" "${API_BASE_URL}/users" | \
    (command -v jq &>/dev/null && jq . || cat)
EOF
    chmod +x "$script_path"
}

_generate_add_user_script() {
    local script_path="${MGMT_SCRIPTS_DIR}/add-user.sh"
    log_info "  -> Generating: ${script_path}"

    cat > "$script_path" <<EOF
#!/usr/bin/env bash
# Adds a new user via the application API.

if [[ \$# -ne 2 ]]; then
    echo "Usage: \$0 <username> <password>"
    exit 1
fi

USERNAME="\$1"
PASSWORD="\$2"

echo "Attempting to add user: \${USERNAME}"

curl -fs -X POST \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"username": "'"\${USERNAME}"'", "password": "'"\${PASSWORD}"'"}' \
    "${API_BASE_URL}/users"
EOF
    chmod +x "$script_path"
}


# --- Main Function ---

main() {
    log_info "🚀 Generating API-based Management Scripts..."

    # 1. Pre-flight checks
    if [[ ! -f "$SECRETS_ENV_FILE" ]]; then
        die "$E_MISSING_DEP" "Secrets file not found at '${SECRETS_ENV_FILE}'. Please run 'generate-credentials.sh' first."
    fi
    mkdir -p "$MGMT_SCRIPTS_DIR"

    # 2. Load the API Key
    log_info "Loading API key from secrets file..."
    # Source the file to load the variables. We only need API_KEY.
    # shellcheck source=/dev/null
    source <(grep 'API_KEY' "$SECRETS_ENV_FILE")
    if is_empty "$API_KEY"; then
        die "$E_GENERAL" "API_KEY not found or is empty in '${SECRETS_ENV_FILE}'."
    fi

    # 3. Generate the scripts
    _generate_get_health_script
    _generate_list_users_script
    _generate_add_user_script

    # 4. Final Output
    log_warn "The generated scripts in '${MGMT_SCRIPTS_DIR}' contain an embedded API key."
    log_warn "Treat these scripts as sensitive files and manage their permissions carefully."
    log_success "✅ Management scripts generated successfully."
}

# --- Script Execution ---
main "$@"