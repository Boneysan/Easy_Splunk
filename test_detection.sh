#!/bin/bash

# Test compose detection in isolation
echo "=== Testing compose detection ==="

# Test the command directly
echo "1. Testing podman compose version command:"
podman compose version 2>&1

echo -e "\n2. Testing ANSI code removal:"
podman compose version 2>&1 | sed 's/\x1b\[[0-9;]*m//g'

echo -e "\n3. Testing grep for external provider:"
podman compose version 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep "Executing external compose provider" && echo "FOUND" || echo "NOT FOUND"

echo -e "\n4. Testing negation logic:"
! podman compose version 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Executing external compose provider" && echo "NATIVE" || echo "DELEGATED"

echo -e "\n5. Now sourcing and testing the function:"
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
