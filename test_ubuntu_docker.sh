#!/bin/bash

# Test Docker-first auto-detection on Ubuntu
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/core.sh" || {
    log_message() { echo "[$1] $2"; }
}

CONFIG_FILE="${SCRIPT_DIR}/config/active.conf"

# Test the Ubuntu detection logic from orchestrator.sh
test_ubuntu_docker_preference() {
    log_message INFO "Testing Ubuntu Docker-first preference logic"
    
    unset CONTAINER_RUNTIME  # Clear any existing value
    
    local prefer_docker=false
    local os_name=""
    
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release 2>/dev/null || true
        os_name="${ID:-unknown}"
        
        # Docker-first for Ubuntu/Debian systems
        if [[ "$os_name" =~ ^(ubuntu|debian)$ ]]; then
            prefer_docker=true
            log_message INFO "Ubuntu/Debian system detected - Docker preferred for better ecosystem compatibility"
        fi
    fi
    
    # Apply Docker-first preference if not explicitly configured
    if [[ "$prefer_docker" == "true" ]] && [[ -z "${CONTAINER_RUNTIME:-}" ]]; then
        if command -v docker &>/dev/null; then
            export CONTAINER_RUNTIME="docker"
            log_message SUCCESS "Auto-selected Docker runtime for $os_name system"
        else
            log_message WARN "Docker preferred for $os_name but not available - will detect available runtime"
        fi
    fi
    
    echo "Result: CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-unset}"
    echo "OS detected: $os_name"
    echo "Docker preference activated: $prefer_docker"
}

test_ubuntu_docker_preference
