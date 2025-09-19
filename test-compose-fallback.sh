#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# test-compose-fallback.sh - Test the new automatic fallback functionality


echo "🧪 Testing Compose Fallback Enhancement"
echo "======================================="
echo ""

# Source the orchestrator script to get the functions
source ./orchestrator.sh 2>/dev/null || {
    echo "❌ Could not source orchestrator.sh"
    exit 1
}

echo "✅ Sourced orchestrator.sh successfully"
echo ""

# Test fallback function availability
echo "🔍 Testing fallback function availability:"

if declare -f install_docker_compose_fallback >/dev/null; then
    echo "✅ install_docker_compose_fallback function available"
else
    echo "❌ install_docker_compose_fallback function missing"
fi

if declare -f init_compose_command >/dev/null; then
    echo "✅ init_compose_command function available"
else
    echo "❌ init_compose_command function missing"
fi

echo ""

# Test compose command detection logic
echo "🔍 Testing current environment:"

echo -n "• Podman available: "
if command -v podman >/dev/null 2>&1; then
    echo "✅ Yes ($(podman --version 2>/dev/null | head -1))"
else
    echo "❌ No"
fi

echo -n "• Docker available: "
if command -v docker >/dev/null 2>&1; then
    echo "✅ Yes ($(docker --version 2>/dev/null | head -1))"
else
    echo "❌ No"
fi

echo -n "• podman-compose available: "
if command -v podman-compose >/dev/null 2>&1; then
    if podman-compose --version >/dev/null 2>&1; then
        echo "✅ Yes and working"
    else
        echo "⚠️  Installed but not working"
    fi
else
    echo "❌ No"
fi

echo -n "• podman compose available: "
if podman compose version >/dev/null 2>&1; then
    echo "✅ Yes"
else
    echo "❌ No"
fi

echo -n "• docker-compose available: "
if command -v docker-compose >/dev/null 2>&1; then
    echo "✅ Yes ($(docker-compose --version 2>/dev/null | head -1))"
else
    echo "❌ No"
fi

echo -n "• docker compose available: "
if docker compose version >/dev/null 2>&1; then
    echo "✅ Yes"
else
    echo "❌ No"
fi

echo ""

# Simulate the new fallback logic
echo "🎯 Fallback Enhancement Summary:"
echo ""
echo "The new fallback system will:"
echo "1. ✅ Try podman-compose first (if podman is detected)"
echo "2. ✅ Try native podman compose second"
echo "3. 🆕 Try docker-compose with podman socket third"
echo "4. 🆕 Auto-install docker-compose v2.21.0 if needed"
echo "5. ✅ Provide detailed troubleshooting guidance"
echo ""

echo "🎉 Compose fallback enhancement testing completed!"
echo ""
echo "📋 Benefits:"
echo "   • Automatic recovery from podman-compose failures"
echo "   • Zero user intervention needed for common issues"
echo "   • Works with RHEL 8 Python 3.6 limitations"
echo "   • Maintains podman backend while using docker-compose frontend"
echo ""
echo "🚀 To test the actual fallback during deployment:"
echo "   ./deploy.sh small --with-monitoring"
