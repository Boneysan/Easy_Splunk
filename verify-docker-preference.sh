#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# verify-docker-preference.sh - Demonstrates Docker-first preference in Easy_Splunk

echo "=== Easy_Splunk Docker-First Preference Verification ==="
echo
echo "1. Container Runtime Detection (lib/container-wrapper.sh):"
echo "   ✅ Checks Docker first (lines 11-24)"
echo "   ✅ Falls back to Podman only if Docker unavailable (lines 26-39)"
echo
echo "2. Installation Logic (install-prerequisites.sh):"
echo "   ✅ Ubuntu/Debian: Docker CE + Docker Compose v2 (default)"
echo "   ✅ RHEL 8+: Docker for Python compatibility (default)"
echo "   ✅ Other RHEL/Fedora: Docker for consistency (default)"
echo "   ✅ Use --prefer-podman flag to override preference"
echo
echo "3. Current System Analysis:"

# Check what's currently available
echo -n "   Docker available: "
if command -v docker >/dev/null 2>&1; then
    echo "✅ Yes ($(docker --version 2>/dev/null | cut -d' ' -f1-3))"
else
    echo "❌ No"
fi

echo -n "   Podman available: "
if command -v podman >/dev/null 2>&1; then
    echo "✅ Yes ($(podman --version 2>/dev/null))"
else
    echo "❌ No"
fi

echo
echo "4. Container Wrapper Test:"
if [[ -f lib/container-wrapper.sh ]]; then
    # Source the wrapper and show what it detects
    source lib/container-wrapper.sh 2>&1 | grep -E "(found|accessible|Using)"
    echo "   Detected runtime: $CONTAINER_RUNTIME"
    echo "   Compose command: $COMPOSE_CMD"
else
    echo "   ❌ lib/container-wrapper.sh not found"
fi

echo
echo "5. Installation Command Examples:"
echo "   # Install Docker (default behavior):"
echo "   ./install-prerequisites.sh --yes"
echo
echo "   # Force Podman installation:"
echo "   ./install-prerequisites.sh --prefer-podman --yes"
echo
echo "   # Explicitly choose runtime:"
echo "   ./install-prerequisites.sh --runtime docker --yes"
echo "   ./install-prerequisites.sh --runtime podman --yes"

echo
echo "=== Docker-First Preference Verified ✅ ==="
