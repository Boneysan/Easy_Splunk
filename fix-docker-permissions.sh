#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# fix-docker-permissions.sh - Fix Docker group permissions for non-root users

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Docker Permissions Fix Script ===${NC}"
echo

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    echo -e "${YELLOW}[INFO]${NC} Running as root - Docker group membership not required"
    echo -e "${GREEN}[OK  ]${NC} Root users can access Docker without group membership"
    exit 0
fi

# Get current user
CURRENT_USER=$(whoami)
echo -e "${BLUE}[INFO]${NC} Current user: $CURRENT_USER"

# Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}[ERROR]${NC} Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if user is already in docker group
if groups "$CURRENT_USER" | grep -q "\bdocker\b"; then
    echo -e "${GREEN}[OK  ]${NC} User '$CURRENT_USER' is already in the docker group"
    
    # Test Docker access
    if docker ps >/dev/null 2>&1; then
        echo -e "${GREEN}[OK  ]${NC} Docker access is working correctly"
        exit 0
    else
        echo -e "${YELLOW}[WARN]${NC} User is in docker group but Docker access is not working"
        echo -e "${YELLOW}[INFO]${NC} This may require logging out and back in, or restarting the session"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} User '$CURRENT_USER' is not in the docker group"
    echo -e "${BLUE}[INFO]${NC} Adding user to docker group..."
    
    # Add user to docker group
    if sudo usermod -aG docker "$CURRENT_USER"; then
        echo -e "${GREEN}[OK  ]${NC} User '$CURRENT_USER' added to docker group"
    else
        echo -e "${RED}[ERROR]${NC} Failed to add user to docker group"
        exit 1
    fi
fi

echo
echo -e "${BLUE}=== Activating Docker Group Membership ===${NC}"

# Check current groups
echo -e "${BLUE}[INFO]${NC} Current groups: $(groups)"

# Try to activate new group membership
echo -e "${BLUE}[INFO]${NC} Activating docker group membership..."

# Test if we can use newgrp to activate the group
if newgrp docker -c "groups | grep -q docker"; then
    echo -e "${GREEN}[OK  ]${NC} Docker group activated successfully"
    
    # Test Docker access in the new group context
    if newgrp docker -c "docker ps >/dev/null 2>&1"; then
        echo -e "${GREEN}[OK  ]${NC} Docker access is working in new group context"
        echo
        echo -e "${GREEN}=== Docker Permissions Fixed Successfully! ===${NC}"
        echo -e "${BLUE}[INFO]${NC} You can now use Docker commands without sudo"
        echo -e "${BLUE}[INFO]${NC} Current session has been updated with docker group membership"
    else
        echo -e "${YELLOW}[WARN]${NC} Docker access still not working in group context"
        echo -e "${YELLOW}[INFO]${NC} Manual session restart may be required"
    fi
else
    echo -e "${YELLOW}[WARN]${NC} Could not automatically activate docker group"
    echo
    echo -e "${YELLOW}=== Manual Steps Required ===${NC}"
    echo -e "${BLUE}[INFO]${NC} Please choose one of the following options:"
    echo
    echo -e "${YELLOW}Option 1: Start a new shell session${NC}"
    echo "  newgrp docker"
    echo
    echo -e "${YELLOW}Option 2: Log out and log back in${NC}"
    echo "  exit  # then log back in"
    echo
    echo -e "${YELLOW}Option 3: Restart your terminal/SSH session${NC}"
    echo
    echo -e "${BLUE}[INFO]${NC} After completing one of these steps, verify with:"
    echo "  groups  # Should show 'docker' in the list"
    echo "  docker ps  # Should work without sudo"
fi

echo
echo -e "${BLUE}=== Verification Commands ===${NC}"
echo "After fixing permissions, verify with these commands:"
echo "  groups | grep docker  # Should show docker group"
echo "  docker --version     # Should show Docker version"
echo "  docker compose version  # Should show Compose version"
echo "  docker ps             # Should list containers without permission errors"
