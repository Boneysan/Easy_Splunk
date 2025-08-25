#!/bin/bash

# Test script to verify centralized runtime configuration works
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Testing centralized runtime configuration logic..."
echo "=============================================="

# Test 1: Check if config file is read correctly
echo "Test 1: Reading runtime from config/active.conf"
config_file="${SCRIPT_DIR}/config/active.conf"
if [[ -f "$config_file" ]]; then
    configured_runtime=$(grep -E "^CONTAINER_RUNTIME=" "$config_file" 2>/dev/null | cut -d'=' -f2 | tr -d '"' | tr -d "'")
    if [[ -n "$configured_runtime" ]]; then
        echo "✅ Found configured runtime: $configured_runtime"
    else
        echo "❌ No CONTAINER_RUNTIME found in config file"
    fi
else
    echo "❌ Config file not found: $config_file"
fi

# Test 2: Check Docker-first logic for Ubuntu
echo
echo "Test 2: Docker-first logic for Ubuntu/Debian"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release 2>/dev/null || true
    os_name="${ID:-unknown}"
    echo "Detected OS: $os_name"
    
    if [[ "$os_name" =~ ^(ubuntu|debian)$ ]]; then
        echo "✅ Ubuntu/Debian detected - Docker-first logic should activate"
        if command -v docker &>/dev/null; then
            echo "✅ Docker is available"
        else
            echo "❌ Docker not available - would fall back to available runtime"
        fi
    else
        echo "ℹ️  Not Ubuntu/Debian - Docker-first logic should not activate"
    fi
else
    echo "❌ /etc/os-release not found"
fi

# Test 3: Check available runtimes
echo
echo "Test 3: Available container runtimes"
if command -v docker &>/dev/null; then
    echo "✅ Docker available"
else
    echo "❌ Docker not available"
fi

if command -v podman &>/dev/null; then
    echo "✅ Podman available"
else
    echo "❌ Podman not available"
fi

echo
echo "Test completed!"
echo "=============="
echo "Summary: The scripts should use '$configured_runtime' from config when available,"
echo "         or apply Docker-first logic for Ubuntu/Debian systems when not configured."
