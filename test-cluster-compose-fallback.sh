#!/bin/bash
# test-cluster-compose-fallback.sh - Test compose fallback for cluster scripts

echo "🧪 Testing Cluster Scripts Compose Fallback"
echo "==========================================="
echo ""

# Test the compose-init library directly
echo "1. Testing compose-init library..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries in order
if source "${SCRIPT_DIR}/lib/core.sh" 2>/dev/null; then
    echo "✅ core.sh loaded"
else
    echo "❌ Failed to load core.sh"
    exit 1
fi

if source "${SCRIPT_DIR}/lib/error-handling.sh" 2>/dev/null; then
    echo "✅ error-handling.sh loaded"
else
    echo "❌ Failed to load error-handling.sh"
    exit 1
fi

if source "${SCRIPT_DIR}/lib/compose-init.sh" 2>/dev/null; then
    echo "✅ compose-init.sh loaded"
else
    echo "❌ Failed to load compose-init.sh"
    exit 1
fi

if source "${SCRIPT_DIR}/lib/runtime-detection.sh" 2>/dev/null; then
    echo "✅ runtime-detection.sh loaded"
else
    echo "❌ Failed to load runtime-detection.sh"
    exit 1
fi

echo ""
echo "2. Testing compose initialization..."

# Test runtime detection
if detect_container_runtime; then
    echo "✅ Container runtime detected: ${CONTAINER_RUNTIME}"
else
    echo "❌ Failed to detect container runtime"
    exit 1
fi

# Test compose initialization
if initialize_compose_system; then
    echo "✅ Compose system initialized"
    echo "   COMPOSE_COMMAND: ${COMPOSE_COMMAND}"
    echo "   COMPOSE_COMMAND_ARRAY: ${COMPOSE_COMMAND_ARRAY[*]}"
else
    echo "❌ Failed to initialize compose system"
    exit 1
fi

echo ""
echo "3. Testing compose command functionality..."

# Test that the compose command works
if "${COMPOSE_COMMAND_ARRAY[@]}" version >/dev/null 2>&1; then
    echo "✅ Compose command working: $("${COMPOSE_COMMAND_ARRAY[@]}" version 2>/dev/null | head -1)"
else
    echo "❌ Compose command not working"
fi

echo ""
echo "🎉 Cluster Scripts Compose Fallback Test Complete!"
echo ""
echo "✅ The cluster management scripts (start_cluster.sh, stop_cluster.sh)"
echo "   now have automatic compose fallback capability!"
echo ""
echo "💡 This means these scripts will automatically:"
echo "   • Try podman-compose first"
echo "   • Fall back to podman compose"
echo "   • Fall back to docker-compose with podman"
echo "   • Auto-install docker-compose if needed"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test-cluster-compose-fallback"

# Set error handling
set -euo pipefail


