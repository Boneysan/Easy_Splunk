# Easy Splunk Podman-Compose Workaround Guide

## Issue Description
podman-compose is not working properly on your system. This guide provides multiple solution paths.

## Automated Solutions Available

### 🔧 Run the Automated Fix
```bash
./fix-podman-compose.sh
```

### 🩺 Run System Health Check
```bash
./health_check.sh
```

## Manual Solution Options

### Option 1: Use Native Podman Compose (Recommended)
```bash
# Check if available
podman compose version

# If available, modify Easy Splunk scripts:
# 1. Edit orchestrator.sh
# 2. Replace 'podman-compose' with 'podman compose'
# 3. Test with: ./deploy.sh small --index-name test
```

### Option 2: Docker Alternative
```bash
# Install Docker (RHEL 8)
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# Log out and back in, then:
./install-prerequisites.sh --runtime docker
```

### Option 3: Upgrade Podman
```bash
# On RHEL 8, try newer Podman from container-tools module
sudo dnf module install container-tools:rhel8/common
sudo dnf update podman
```

### Option 4: Use Different Distribution
- Ubuntu 20.04+ or Debian 11+ (better podman-compose support)
- Fedora 35+ (latest container tools)
- Rocky Linux 9+ or AlmaLinux 9+

## Troubleshooting Commands

### Diagnostic Commands
```bash
# Check versions
python3 --version
podman --version
pip3 list | grep podman

# Test basic functionality
podman info
podman run hello-world

# Check SELinux
getenforce
sudo ausearch -m AVC -ts recent
```

### Reset and Retry
```bash
# Reset podman state
podman system reset --force

# Reinstall podman-compose
pip3 uninstall -y podman-compose
pip3 install podman-compose==1.0.6

# Test again
podman-compose --version
```

## Getting Help

If none of these solutions work:

1. **Check the Enhanced Error Messages** - They provide specific troubleshooting steps
2. **Review the Log Files** - Look for detailed error information
3. **Try the Health Check** - Run `./health_check.sh` for comprehensive diagnostics
4. **Open an Issue** - Include your system info and log files

## System Information Template

When reporting issues, include:

```bash
# System Info
cat /etc/os-release
python3 --version
podman --version
getenforce

# Container Tools
dnf list installed | grep container
pip3 list | grep -E "(podman|compose|docker)"

# SELinux Status
sudo sesearch -A -s container_t -t admin_home_t
sudo ausearch -m AVC -ts recent | tail -20
```
