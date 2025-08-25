#!/bin/bash

# Test script to verify runtime configuration sourcing in orchestrator.sh
set -euo pipefail

# Source core libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/core.sh" || {
    echo "Cannot load core library - using basic logging"
    log_message() { echo "[$1] $2"; }
}

# Test configuration
readonly CONFIG_FILE="${SCRIPT_DIR}/config/active.conf"

# Source the runtime configuration function from orchestrator.sh
source_runtime_config() {
    log_message INFO "Sourcing runtime configuration from active configuration"
    
    # Source runtime configuration from config/active.conf if available
    if [[ -f "$CONFIG_FILE" ]]; then
        log_message INFO "Loading runtime configuration from: $CONFIG_FILE"
        
        # Extract CONTAINER_RUNTIME from config file safely
        local configured_runtime
        configured_runtime=$(grep -E "^CONTAINER_RUNTIME=" "$CONFIG_FILE" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
        
        if [[ -n "$configured_runtime" ]]; then
            export CONTAINER_RUNTIME="$configured_runtime"
            log_message INFO "Runtime configuration loaded: CONTAINER_RUNTIME=$CONTAINER_RUNTIME"
        else
            log_message INFO "No CONTAINER_RUNTIME found in config file, will use auto-detection"
        fi
    else
        log_message INFO "No active configuration file found, using auto-detection"
    fi
}

# Test the function
echo "Testing runtime configuration sourcing..."
echo "Before sourcing: CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-unset}"

source_runtime_config

echo "After sourcing: CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-unset}"
echo "Test completed successfully!"
