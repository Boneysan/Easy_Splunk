#!/usr/bin/env bash
# Helper to fetch secrets with fallback. Used by compose and monitoring scripts.
# Returns secret value to stdout or exits with error if not found/accessible.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_CLI="${SCRIPT_DIR}/../security/secrets_manager.sh"

get_secret() {
    local service="$1"
    local key="$2"
    local fallback_file="$3"
    local fallback_default="$4"
    local description="${5:-secret}"

    # Try secrets manager first if available
    if [[ -x "$SECRETS_CLI" ]]; then
        if value=$("$SECRETS_CLI" retrieve_credential "$service" "$key" 2>/dev/null); then
            echo "$value"
            return 0
        fi
    fi

    # Try file fallback if provided
    if [[ -n "$fallback_file" ]] && [[ -f "$fallback_file" ]]; then
        if value=$(cat "$fallback_file" 2>/dev/null); then
            echo "$value"
            return 0
        fi
    fi

    # Use default if provided
    if [[ -n "$fallback_default" ]]; then
        echo "$fallback_default"
        return 0
    fi

    echo "ERROR: Could not retrieve $description" >&2
    return 1
}

# Only execute if run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <service> <key> [fallback_file] [fallback_default] [description]" >&2
        exit 1
    fi
    get_secret "$@"
fi
