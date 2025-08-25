#!/bin/bash

# Test compose detection and OS-specific runtime preferences in isolation
echo "=== Testing compose detection and OS preferences ==="

# Test the command directly
echo "1. Testing podman compose version command:"
podman compose version 2>&1

echo -e "\n2. Testing ANSI code removal:"
podman compose version 2>&1 | sed 's/\x1b\[[0-9;]*m//g'

echo -e "\n3. Testing grep for external provider:"
podman compose version 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "Executing external compose provider" && echo "FOUND" || echo "NOT FOUND"

echo -e "\n4. Testing negation logic:"
! podman compose version 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Executing external compose provider" && echo "NATIVE" || echo "DELEGATED"

echo -e "\n5. Testing OS-specific Docker preference detection:"
echo "================================================================"

# Test Ubuntu/Debian Docker preference
if [[ -f /etc/os-release ]]; then
    source /etc/os-release 2>/dev/null || true
    os_name="${ID:-unknown}"
    
    echo "Detected OS: $os_name"
    
    if [[ "$os_name" =~ ^(ubuntu|debian)$ ]]; then
        echo "✅ Ubuntu/Debian detected - Docker preference should activate"
        echo "   Reason: Better Docker ecosystem compatibility"
        if command -v docker &>/dev/null; then
            echo "   Docker available: $(docker --version 2>/dev/null || echo 'version check failed')"
        else
            echo "   Docker not available - would fall back to available runtime"
        fi
    elif [[ "${VERSION_ID:-}" == "8"* ]] && [[ "$os_name" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
        echo "✅ RHEL 8-family detected - Docker preference should activate"
        echo "   Reason: Python 3.6 compatibility issues with podman-compose"
        if command -v docker &>/dev/null; then
            echo "   Docker available: $(docker --version 2>/dev/null || echo 'version check failed')"
        else
            echo "   Docker not available - would fall back to available runtime"
        fi
    else
        echo "ℹ️  Other OS ($os_name) - Standard runtime detection applies"
    fi
else
    echo "❌ /etc/os-release not found - cannot test OS detection"
fi

echo -e "\n6. Now sourcing and testing the function:"
source lib/core.sh 2>/dev/null || echo "No core.sh"

# Define minimal logging function if needed
if ! type log_info >/dev/null 2>&1; then
    log_info() { echo "[INFO] $*"; }
fi

# Test compose detection logic directly
compose_output=$(podman compose version 2>&1)
compose_exit_code=$?

echo "Exit code: $compose_exit_code"
echo "Output length: ${#compose_output}"

if echo "$compose_output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Executing external compose provider"; then
    echo "External provider detected in output"
else
    echo "No external provider detected in output"
fi

if [[ $compose_exit_code -eq 0 ]] && ! echo "$compose_output" | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Executing external compose provider"; then
    echo "RESULT: podman-compose-native"
elif [[ $compose_exit_code -eq 0 ]]; then
    echo "RESULT: podman-compose-delegated"
else
    echo "RESULT: podman-compose-fallback"
fi
