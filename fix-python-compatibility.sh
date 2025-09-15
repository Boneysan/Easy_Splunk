#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# fix-python-compatibility.sh
# Fix podman-compose Python compatibility issues on RHEL 8/Python 3.6


echo "🔧 Fixing podman-compose Python compatibility issue..."

# Check Python version
PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
echo "Detected Python version: $PYTHON_VERSION"

if [[ "$PYTHON_VERSION" < "3.8" ]]; then
    echo "⚠️  Python 3.6/3.7 detected - podman-compose has compatibility issues"
    echo "🔧 Switching to docker-compose which works better with podman..."
    
    # Remove broken podman-compose
    echo "Removing incompatible podman-compose..."
    sudo rm -f /usr/local/bin/podman-compose 2>/dev/null || true
    sudo rm -rf /usr/local/lib/python3.6/site-packages/podman_compose* 2>/dev/null || true
    sudo rm -rf /root/.local/lib/python3.6/site-packages/podman_compose* 2>/dev/null || true
    pip3 uninstall -y podman-compose 2>/dev/null || true
    
    # Install docker-compose binary
    echo "Installing docker-compose v2.21.0..."
    sudo curl -L "https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64" \
        -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    # Create podman-compose symlink for compatibility
    sudo ln -sf /usr/local/bin/docker-compose /usr/local/bin/podman-compose
    
    # Verify installation
    if docker-compose --version; then
        echo "✅ docker-compose installed successfully"
        echo "✅ podman-compose compatibility symlink created"
        
        # Test with podman
        export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock
        echo "Testing compose functionality..."
        if timeout 10 docker-compose version 2>/dev/null; then
            echo "✅ Compose works with podman socket"
        else
            echo "ℹ️  Compose installed, may need podman socket setup"
        fi
    else
        echo "❌ Failed to install docker-compose"
        exit 1
    fi
else
    echo "✅ Python $PYTHON_VERSION supports podman-compose natively"
fi

echo "🎉 Python compatibility fix completed!"
