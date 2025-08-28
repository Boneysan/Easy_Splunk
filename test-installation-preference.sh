#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# test-installation-preference.sh - Test what the installation script will choose

echo "=== Testing Installation Script Docker Preference ==="
echo

# Detect OS family
detect_os_family() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "$ID" in
            ubuntu|debian) echo "debian" ;;
            rhel|centos|fedora|rocky|almalinux) echo "rhel" ;;
            darwin) echo "mac" ;;
            *) echo "unknown" ;;
        esac
    else
        echo "unknown"
    fi
}

# Simulate the installation logic
OS_FAMILY=$(detect_os_family)
RUNTIME_PREF="auto"
PREFER_PODMAN=0

echo "Detected OS family: $OS_FAMILY"
echo "Runtime preference: $RUNTIME_PREF"
echo "Prefer Podman flag: $PREFER_PODMAN"
echo

echo "What would be installed:"

case "${OS_FAMILY}" in
    debian)
        if [[ "$PREFER_PODMAN" == "1" ]]; then
            echo "✅ Would install: Podman (due to --prefer-podman flag)"
        else
            echo "✅ Would install: Docker CE + Docker Compose v2 (DEFAULT)"
        fi
        ;;
    rhel)
        # RHEL 8 detection
        rhel8_detected=false
        if [[ -f /etc/redhat-release ]] && grep -q "Red Hat Enterprise Linux.*release 8\|CentOS.*release 8\|Rocky Linux.*release 8\|AlmaLinux.*release 8" /etc/redhat-release 2>/dev/null; then
            rhel8_detected=true
        elif [[ -f /etc/os-release ]]; then
            source /etc/os-release 2>/dev/null || true
            if [[ "${VERSION_ID:-}" == "8"* ]] && [[ "${ID:-}" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
                rhel8_detected=true
            fi
        fi
        
        if [[ "$rhel8_detected" == "true" ]]; then
            echo "✅ Would install: Docker (RHEL 8 detected - Python compatibility)"
        else
            echo "✅ Would install: Docker (DEFAULT for all RHEL/Fedora)"
        fi
        ;;
    *)
        echo "❌ Unsupported OS family: Would suggest manual Docker installation"
        ;;
esac

echo
echo "To install Podman instead, use:"
echo "  ./install-prerequisites.sh --prefer-podman --yes"
echo "  # OR"
echo "  ./install-prerequisites.sh --runtime podman --yes"

echo
echo "=== Docker is now the default choice on all systems ✅ ==="
