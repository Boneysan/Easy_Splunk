# 🐳 Docker vs Podman Decision Guide

This guide explains when and why Easy_Splunk automatically chooses Docker over Podman, ensuring optimal compatibility and performance for your deployment.

## 📊 Decision Matrix

| Scenario | Docker Preferred | Podman Preferred | Reasoning |
|----------|------------------|------------------|-----------|
| **RHEL 8 / CentOS 8** | ✅ **Yes** | ❌ No | Python 3.6 compatibility issues with podman-compose |
| **Rocky Linux 8** | ✅ **Yes** | ❌ No | Inherits RHEL 8 Python limitations |
| **AlmaLinux 8** | ✅ **Yes** | ❌ No | Inherits RHEL 8 Python limitations |
| **Ubuntu 20.04+** | ✅ **Yes** | ⚠️ Optional | Better ecosystem integration and documentation |
| **Debian 10+** | ✅ **Yes** | ⚠️ Optional | Mature Docker tooling and community support |
| **Fedora 35+** | ⚠️ Optional | ✅ **Yes** | Podman is Fedora's native container runtime |
| **RHEL 9+** | ⚠️ Optional | ✅ **Yes** | Modern Python 3.9+ supports podman-compose |
| **Air-gapped** | ✅ **Yes** | ❌ No | Docker's mature air-gapped tooling, better bundle compatibility |
| **CI/CD Pipelines** | ✅ **Yes** | ❌ No | Docker's dominant position in CI/CD |

## 🔍 Detailed Explanations

### RHEL 8 / CentOS 8 / Rocky Linux 8 / AlmaLinux 8

**Why Docker is preferred:**
- **Python 3.6 Limitation**: RHEL 8 ships with Python 3.6, but `podman-compose` requires Python 3.8+ for the walrus operator (`:=`)
- **Syntax Error**: `SyntaxError: invalid syntax` when running podman-compose commands
- **Compatibility**: Docker Compose works reliably with Python 3.6

**Evidence:**
```bash
# This fails on RHEL 8 with Python 3.6:
pip3 install podman-compose
podman-compose --version
# SyntaxError: invalid syntax

# Docker Compose works fine:
docker-compose --version
# docker-compose version 2.21.0
```

### Ubuntu / Debian Systems

**Why Docker is preferred:**
- **Ecosystem Maturity**: Docker has better integration with Ubuntu/Debian package management
- **Documentation**: Vast majority of tutorials and documentation reference Docker
- **Tooling**: Better integration with Docker Desktop, Docker Hub, and development tools
- **Community Support**: Larger community and more tested configurations

**Performance Impact:** Minimal - both runtimes have similar performance for Splunk workloads.

### Fedora / RHEL 9+ Systems

**Why Podman is preferred:**
- **Native Runtime**: Podman is Red Hat's recommended container runtime for modern Fedora/RHEL
- **Security**: Rootless containers by default (better security model)
- **Modern Python**: Python 3.9+ supports all podman-compose features
- **Integration**: Better integration with systemd and SELinux

### Air-gapped Environments

**Why Docker is preferred:**
- **Mature Tooling**: Docker has more mature air-gapped deployment tools and workflows
- **Registry Support**: Better support for private registries and image mirroring
- **Enterprise Adoption**: More widely adopted in enterprise air-gapped scenarios
- **Bundle Compatibility**: Optimized for the three-step air-gapped deployment process:
  1. Generate compose with size templates (`--dry-run`)
  2. Create air-gapped bundle with Docker images
  3. Deploy on offline systems with better Docker compatibility
- **Documentation**: More comprehensive air-gapped deployment guides and troubleshooting
- **Image Transfer**: Proven workflows for `docker save/load` operations in air-gapped environments

## ⚙️ Automatic Detection Logic

The toolkit automatically detects your environment and makes the optimal choice:

```bash
# In lib/runtime-detection.sh
detect_optimal_runtime() {
    if is_rhel8_compatible; then
        echo "docker"  # Python 3.6 compatibility
    elif is_fedora_modern; then
        echo "podman"  # Native runtime
    elif is_ubuntu_debian; then
        echo "docker"  # Ecosystem maturity
    else
        echo "podman"  # Default modern choice
    fi
}
```

## 🔄 Manual Override

You can always override the automatic choice:

```bash
# Force Docker
export PREFERRED_RUNTIME="docker"
./install-prerequisites.sh

# Force Podman
export PREFERRED_RUNTIME="podman"
./install-prerequisites.sh

# Force specific compose tool
export COMPOSE_TOOL="docker-compose"
./deploy.sh
```

## 📈 Performance Comparison

| Metric | Docker | Podman | Notes |
|--------|--------|--------|-------|
| **Startup Time** | ~2-3s | ~2-3s | Similar for Splunk workloads |
| **Memory Usage** | ~50MB | ~45MB | Minimal difference |
| **Disk Usage** | ~2GB | ~2GB | Same image layers |
| **Network I/O** | Fast | Fast | No significant difference |
| **Security** | Rootful by default | Rootless by default | Podman has security advantage |
| **Compatibility** | Universal | Modern systems | Docker works everywhere |

## 🚨 Common Issues & Solutions

### Issue: "podman-compose: command not found"
**Solution:** On RHEL 8, this is expected. The toolkit automatically uses Docker instead.

### Issue: "docker: permission denied"
**Solution:** Add user to docker group or use sudo:
```bash
sudo usermod -aG docker $USER
# Logout and login again, or:
newgrp docker
```

### Issue: "podman: command not found"
**Solution:** Install Podman:
```bash
# RHEL/Fedora
sudo dnf install podman

# Ubuntu/Debian
sudo apt install podman
```

## 📚 Related Documentation

- [Installation Guide](docs/INSTALLATION.md) - Complete setup instructions
- [Enhanced Error Handling](ENHANCED_ERROR_HANDLING_GUIDE.md) - Troubleshooting runtime issues
- [Python Compatibility Fix](fix-python-compatibility.sh) - RHEL 8 specific fixes
- [Podman Compose Fix](fix-podman-compose.sh) - Alternative installation methods

## 🎯 Recommendation Summary

**For most users:**
- **RHEL 8 / Ubuntu / Debian**: Use Docker (automatic)
- **Fedora / RHEL 9+**: Use Podman (automatic)
- **Air-gapped**: Use Docker (better tooling)
- **CI/CD**: Use Docker (industry standard)

The automatic detection ensures you get the best experience without manual configuration!
