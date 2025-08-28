#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# quick-fixes.sh - One-stop shop for all Easy_Splunk immediate s    6)
        echo "🧪 Te    7)
        echo "🧪 Testing all scripts status..."
        if [[ -x "./function-loading-status.sh" ]]; then
            ./function-loading-status.sh
        else
            echo "❌ function-loading-status.sh not found or not executable"
        fi
        ;;
    8)
        echo "📋 Displaying complete fix summary..."
        if [[ -x "./final-fix-summary.sh" ]]; then
            ./final-fix-summary.sh
        else
            echo "❌ final-fix-summary.sh not found or not executable"
        fi
        ;;
    9) status..."
        if [[ -x "./function-loading-status.sh" ]]; then
            ./function-loading-status.sh
        else
            echo "❌ function-loading-status.sh not found or not executable"
        fi
        ;;
    7)
        echo "📋 Displaying complete fix summary..."
        if [[ -x "./final-fix-summary.sh" ]]; then
            ./final-fix-summary.sh
        else
            echo "❌ final-fix-summary.sh not found or not executable"
        fi
        ;;
    8)o pipefail

echo "🚨 EASY_SPLUNK IMMEDIATE SOLUTIONS"
echo "=================================="
echo ""

echo "This script provides immediate fixes for common Easy_Splunk issues."
echo "Choose your fix option:"
echo ""

echo "1. 🔧 Function Loading Fixes (recommended first)"
echo "2. 🐍 Python Compatibility Fix (RHEL 8)"
echo "3. 🔄 Podman-Compose Fix"
echo "4. 🐳 Install Docker Compose"
echo "5. 🔑 Fix Docker Permissions (Docker group access)"
echo "6. ✅ Verify Installation (Phase 2 after logout/login)"
echo "7. 🧪 Test All Scripts Status"
echo "8. 📋 View Complete Fix Summary"
echo "9. 🆕 Test New Compose Fallback System"
echo "0. Exit"
echo ""

read -p "Select option (0-9): " choice

case $choice in
    1)
        echo "🔧 Applying comprehensive function loading fixes..."
        if [[ -x "./fix-all-function-loading.sh" ]]; then
            ./fix-all-function-loading.sh
        else
            echo "❌ fix-all-function-loading.sh not found or not executable"
        fi
        ;;
    2)
        echo "🐍 Applying Python compatibility fix..."
        if [[ -x "./fix-python-compatibility.sh" ]]; then
            ./fix-python-compatibility.sh
        else
            echo "❌ fix-python-compatibility.sh not found or not executable"
        fi
        ;;
    3)
        echo "🔄 Applying podman-compose fix..."
        if [[ -x "./fix-podman-compose.sh" ]]; then
            ./fix-podman-compose.sh
        else
            echo "❌ fix-podman-compose.sh not found or not executable"
        fi
        ;;
    4)
        echo "🐳 Installing Docker Compose..."
        echo "This will install Docker Compose v2.21.0 directly"
        read -p "Continue? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "Downloading Docker Compose..."
            sudo curl -L "https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
            sudo chmod +x /usr/local/bin/docker-compose
            echo "✅ Docker Compose installed successfully"
            docker-compose --version
        else
            echo "Cancelled."
        fi
        ;;
    5)
        echo "🔑 Fixing Docker permissions..."
        if [[ -x "./fix-docker-permissions.sh" ]]; then
            ./fix-docker-permissions.sh
        else
            echo "❌ fix-docker-permissions.sh not found or not executable"
            echo "🔧 Manual fix:"
            echo "   sudo usermod -aG docker \$USER"
            echo "   newgrp docker"
        fi
        ;;
    6)
        echo "✅ Running installation verification..."
        if [[ -x "./verify-installation.sh" ]]; then
            ./verify-installation.sh
        else
            echo "❌ verify-installation.sh not found or not executable"
            echo "🔧 Manual verification:"
            echo "   docker ps  # Should work without sudo"
            echo "   docker run hello-world  # Test basic functionality"
        fi
        ;;
    7)
        echo "🧪 Testing all scripts status..."
        if [[ -x "./function-loading-status.sh" ]]; then
            ./function-loading-status.sh
        else
            echo "❌ function-loading-status.sh not found or not executable"
        fi
        ;;
    6)
        echo "📋 Displaying complete fix summary..."
        if [[ -x "./final-fix-summary.sh" ]]; then
            ./final-fix-summary.sh
        else
            echo "❌ final-fix-summary.sh not found or not executable"
        fi
        ;;
    7)
        echo "🆕 Testing new compose fallback system..."
        if [[ -x "./test-compose-fallback-simple.sh" ]]; then
            ./test-compose-fallback-simple.sh
        else
            echo "❌ test-compose-fallback-simple.sh not found or not executable"
            echo "🔄 Running basic fallback test..."
            echo ""
            echo "Current environment:"
            echo -n "• Podman: "
            if command -v podman >/dev/null 2>&1; then
                echo "✅ Available"
            else
                echo "❌ Not available"
            fi
            echo -n "• Docker: "
            if command -v docker >/dev/null 2>&1; then
                echo "✅ Available"
            else
                echo "❌ Not available"
            fi
            echo -n "• podman-compose: "
            if command -v podman-compose >/dev/null 2>&1; then
                echo "✅ Available"
            else
                echo "❌ Not available"
            fi
            echo -n "• docker-compose: "
            if command -v docker-compose >/dev/null 2>&1; then
                echo "✅ Available"
            else
                echo "❌ Not available"
            fi
            echo ""
            echo "✨ New Feature: The toolkit will now automatically:"
            echo "   1. Try podman-compose first"
            echo "   2. Try native podman compose"
            echo "   3. 🆕 Fallback to docker-compose with podman"
            echo "   4. 🆕 Auto-install docker-compose if needed"
        fi
        ;;
    0)
        echo "Exiting."
        exit 0
        ;;
    *)
        echo "❌ Invalid option. Please select 0-9."
        exit 1
        ;;
esac

echo ""
echo "✅ Fix application completed!"
echo ""
echo "📖 Next Steps:"
echo "   1. Test your deployment: ./deploy.sh small"
echo "   2. Generate credentials: ./generate-credentials.sh"
echo "   3. Check health: ./health_check.sh"
echo ""
echo "📋 For more help, see the README.md file or run ./final-fix-summary.sh"
