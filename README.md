# Easy_Splunk

A comprehensive shell-based orchestration toolkit for deploying, managing, and securing a containerized Splunk cluster on Docker or Podman.  
Supports air-gapped environments, automated credential/TLS generation, integrated monitoring (Prometheus + Grafana), and hardened RHEL/Fedora deployments.

**✅ Latest Update**: Enhanced error handling with detailed troubleshooting steps and comprehensive guidance for common deployment issues. Fixed container runtime detection for RHEL 8, CentOS 8, Rocky Linux, and other enterprise distributions.

**🚨 Having Issues?** Jump to [Immediate Solutions](#-immediate-solutions-troubleshooting) for quick fixes.

---

# Easy_Splunk

A shell-based orchestration toolkit for deploying, managing, and securing a containerized Splunk cluster on Docker or Podman. Supports air‑gapped installs, automated credentials/TLS, and optional monitoring (Prometheus + Grafana).

---

## � Enhanced Error Handling

The toolkit now features comprehensive error handling with detailed troubleshooting guidance:

### **Before (Original)**
```bash
[ERROR] Compose command failed: podman-compose
[ERROR] Installation verification failed.
```

### **After (Enhanced)**
```bash
[ERROR] Compose verification failed - podman-compose not working
[INFO ] Troubleshooting steps:
[INFO ] 1. Try: podman-compose --version
[INFO ] 2. Check: pip3 list | grep podman-compose  
[INFO ] 3. Reinstall: pip3 install --user podman-compose==1.0.6
[INFO ] 4. Configure PATH: export PATH=$PATH:$HOME/.local/bin
[INFO ] 5. Alternative: Use native 'podman compose' if available
[INFO ] 6. Verify runtime: podman --version
[INFO ] 7. Logs available at: ./install.log
```

### **Error Categories**
- **Compose Failures**: Docker/Podman compose issues with step-by-step fixes
- **Installation Errors**: Package manager and pip3 installation guidance
- **Runtime Issues**: Container runtime detection and configuration help
- **Network Problems**: Connectivity, firewall, and service accessibility guidance
- **Permission Errors**: File system access and SELinux troubleshooting

### **Test Enhanced Errors**
```bash
# Demonstration of enhanced error handling
./test-enhanced-errors.sh

# Complete workflow demonstration
./demonstrate-enhanced-workflow.sh

# Automated fix for podman-compose issues
./fix-podman-compose.sh

# Fix Python compatibility issues (RHEL 8 specific)
./fix-python-compatibility.sh
```

### **Python Compatibility Fix (RHEL 8)**
RHEL 8 ships with Python 3.6, but podman-compose requires Python 3.8+ for the walrus operator (`:=`). 

**Issue**: `SyntaxError: invalid syntax` when running podman-compose
**Solution**: The toolkit now automatically detects RHEL 8 and prefers Docker for better compatibility

**🆕 Automatic RHEL 8 Optimization:**
- **Auto-detection**: Recognizes RHEL 8, CentOS 8, Rocky Linux 8, AlmaLinux 8
- **Smart Runtime Selection**: Automatically prefers Docker over Podman on RHEL 8
- **Seamless Experience**: Zero user intervention required
- **Fallback Support**: Enhanced compose fallback system as backup

```bash
# Automatic RHEL 8 optimization (recommended)
./install-prerequisites.sh --yes        # Auto-detects RHEL 8, prefers Docker

# Manual fix for existing installations
./fix-python-compatibility.sh

# Manual docker-compose installation
sudo rm -f /usr/local/bin/podman-compose
sudo curl -L "https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -sf /usr/local/bin/docker-compose /usr/local/bin/podman-compose
```

### **Ubuntu/Debian Docker Optimization**
Ubuntu and Debian systems benefit from Docker's mature ecosystem and better integration with the broader containerization landscape.

**🆕 Automatic Ubuntu/Debian Optimization:**
- **Auto-detection**: Recognizes Ubuntu 20.04+, Debian 10+
- **Smart Runtime Selection**: Automatically prefers Docker over Podman on Ubuntu/Debian
- **Ecosystem Compatibility**: Better integration with Docker tooling and documentation
- **Seamless Experience**: Zero user intervention required

```bash
# Automatic Ubuntu/Debian optimization (recommended)
./install-prerequisites.sh --yes        # Auto-detects Ubuntu/Debian, prefers Docker

# Ubuntu-specific Docker installation examples
# Option 1: Official Docker repository (recommended)
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2

# Option 2: Docker CE from Docker's official repository
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Verify installation
docker --version && docker compose version
```

### **OS-Specific Optimization Details**
For detailed information about OS-specific optimizations:

```bash
# RHEL 8 Docker preference details
./rhel8-docker-preference-summary.sh

# Ubuntu/Debian Docker preference details  
./ubuntu-docker-preference-summary.sh

# Test OS-specific detection and preferences
./test_detection.sh
./test-docker-compatibility.sh
```

### **Function Loading Fixes**
All scripts now include comprehensive fallback functions to ensure reliability even when the main error handling library fails to load.

**Fixed Issues**:
- ✅ `with_retry: command not found` - Added fallback with `--retries` argument support
- ✅ `enhanced_installation_error: command not found` - Added fallback with troubleshooting guidance
- ✅ `log_message: command not found` - Added color-coded logging fallback
- ✅ Password validation regex - Fixed over-escaped special character pattern
- ✅ All critical scripts now work independently with local fallback functions

**Available Function Loading Test Scripts**:
```bash
# Test all critical scripts for function loading issues
./function-loading-status.sh

# Test specific functionality
./debug-password-validation.sh

# Apply comprehensive fixes to all scripts
./fix-all-function-loading.sh
```

---

## 🔄 Automatic Compose Fallback System

**NEW FEATURE**: The toolkit now includes intelligent automatic fallback from podman-compose to docker-compose when compose failures occur.

### **Fallback Logic**
```bash
Level 1: Try podman-compose
   ├─ If available and working → Use it
   └─ If not available/broken → Go to Level 2

Level 2: Try podman compose (native)
   ├─ If available and working → Use it  
   └─ If not available/broken → Go to Level 3

Level 3: Try docker-compose with podman
   ├─ If docker-compose available → Use with podman socket
   └─ If not available → Go to Level 4

Level 4: Auto-install docker-compose
   ├─ Download docker-compose v2.21.0
   ├─ Install to /usr/local/bin/
   ├─ Configure podman socket
   └─ Ready to use!
```

### **Benefits**
- ✅ **Zero User Intervention**: Automatic recovery from compose failures
- ✅ **RHEL 8 Compatible**: Works with Python 3.6 limitations  
- ✅ **Seamless Operation**: No deployment interruption
- ✅ **Smart Detection**: Intelligent environment analysis
- ✅ **Robust Recovery**: Multiple fallback levels ensure success

### **User Experience**
```bash
# Before: Manual intervention required
[ERROR] podman-compose not working
# User has to manually fix compose issues

# After: Automatic recovery
[INFO ] Trying podman-compose...
[WARN ] podman-compose failed, trying podman compose...
[INFO ] Installing docker-compose fallback...
[OK   ] Compose command ready: docker-compose
```

### **Test Compose Fallback**
```bash
# Test the fallback system
./quick-fixes.sh  # Select option 7
./test-compose-fallback-simple.sh
./compose-fallback-summary.sh
```

### **Automated Fallback System**
The toolkit now includes intelligent fallback logic for compose implementations:

- **Podman Primary**: Tries `podman-compose` → `podman compose` → **automatic docker-compose fallback**
- **Docker Primary**: Tries `docker-compose` → `docker compose`
- **Smart Recovery**: Automatically installs docker-compose v2.21.0 if podman options fail
- **Socket Detection**: Automatically configures docker-compose to work with podman sockets

**Fallback Sequence for Podman**:
1. Try `podman-compose` (Python implementation)
2. Try `podman compose` (native implementation)  
3. **NEW**: Try `docker-compose` with podman socket
4. **NEW**: Auto-install `docker-compose` v2.21.0 if needed
5. Provide detailed troubleshooting if all options fail

### **Automated Fixes Available**
- **./fix-podman-compose.sh** - Comprehensive fix for podman-compose issues on RHEL 8
- **./fix-python-compatibility.sh** - Fix Python 3.6/3.8+ compatibility issues with podman-compose
- **Targeted troubleshooting** - Specific commands for your exact error scenario
- **SELinux integration** - Automatic container policy fixes for enterprise distributions

---

## �📐 Architecture Overview

┌─────────────────┐
│   Users/Apps    │
└─────────┬───────┘
│
┌─────────▼───────┐
│  Search Head    │ :8001
│    (Captain)    │
└─────────┬───────┘
│
┌─────────▼───────┐     ┌─────────────┐
│ Cluster Master  │     │ Monitoring  │
│   (License)     │     │   Stack     │
│     :8000       │     │ Prom:9090   │
└─────────┬───────┘     │ Graf:3000   │
│             └─────────────┘
┌─────────▼─────────────────────────────┐
│         Indexer Cluster               │
│  ┌───────┐  ┌───────┐  ┌───────┐      │
│  │ Index │  │ Index │  │ Index │      │
└────────────────────────────────────────

---

## 🚀 Quick Start

### **Supported Operating Systems**
- ✅ **RHEL 8+** (Red Hat Enterprise Linux) - *Docker-optimized*
- ✅ **CentOS 8+** / **Rocky Linux 8+** / **AlmaLinux 8+** - *Docker-optimized*
- ✅ **Ubuntu 20.04+** / **Debian 10+** - *Docker-optimized*
- ✅ **Fedora 35+**
- ✅ **WSL2** (Windows Subsystem for Linux)

**Docker-optimized** = Automatically prefers Docker for optimal compatibility

### **Installation Steps**

The installation process uses a **two-phase approach** for reliable Docker group permission handling:

#### **Phase 1: Install Prerequisites**
```bash
# 1) Clone and enter
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

# 2) Make all shell scripts executable (if needed)
find . -name "*.sh" -type f -exec chmod 755 {} \;

# 3) Phase 1: Install prerequisites (container runtime and permissions)
./install-prerequisites.sh --yes

# 4) Phase 2: Log out and back in, then verify installation
exit
# (log back in to your system)

# 5) Verify installation and get ready to deploy
./verify-installation.sh

# 6) Deploy a cluster with monitoring
./deploy.sh small --with-monitoring

# 7) Health check
./health_check.sh
```

#### **Why Two Phases?**
- **Phase 1** (`install-prerequisites.sh`): Installs Docker/Podman and adds your user to the docker group
- **Session Restart**: Required for group membership changes to take effect (Linux limitation)
- **Phase 2** (`verify-installation.sh`): Confirms everything works and you're ready to deploy

#### **Quick Installation (if you understand the requirements)**
```bash
# All-in-one for experienced users who will log out/in manually
./install-prerequisites.sh --yes && echo "⚠️ Log out/in, then run: ./verify-installation.sh"
```

---

## 🚨 Immediate Solutions (Troubleshooting)

If you encounter function loading errors or podman-compose issues, here are immediate fixes:

### **🚀 Quick Fix Menu (Recommended)**
```bash
./quick-fixes.sh
```
This interactive script provides all fixes in one place with guided options.

### **🆕 Test New Compose Fallback System**
```bash
./quick-fixes.sh  # Select option 7
# OR run directly:
./test-compose-fallback-simple.sh
```
The new automatic fallback system eliminates the need for manual compose fixes.

### **Option 1: Run the automated fix script**
```bash
./fix-podman-compose.sh
```

### **Option 2: Use the Python compatibility fix**
```bash
./fix-python-compatibility.sh
```

### **Option 3: Switch to Docker Compose (Recommended)**
Since you're having podman-compose issues, install Docker Compose directly:
```bash
# Install Docker Compose v2
curl -L https://github.com/docker/compose/releases/download/v2.21.0/docker-compose-linux-x86_64 -o /usr/local/bin/docker-compose
chmod +x /usr/local/bin/docker-compose

# Verify installation
docker-compose --version
```

### **Option 4: Try native Podman Compose**
Newer versions of Podman include built-in compose support:
```bash
# Check if available
podman compose --help

# If available, the toolkit should detect and use it automatically
```

### **Root Cause Analysis**
The issues you're seeing:
- **Python 3.6 Compatibility** - podman-compose has known issues with older Python versions
- **Missing podman-compose** - The package may not be properly installed
- **Package Manager Detection** - The script is having trouble with your package manager

### **Alternative Approach**
If the fixes don't work, you can bypass podman entirely:
```bash
# Install Docker instead of Podman
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker $USER

# Log out and back in, then retry
./deploy.sh medium --index-name my_app_prod --splunk-user admin
```

### **Docker Group Permission Issues**
If you see `[WARN] User not in docker group - logout/login may be required` or permission denied errors when running Docker commands:

**🆕 Automated Fix (Recommended):**
```bash
# Run the automated Docker permissions fix
./fix-docker-permissions.sh
```

**For root users:**
```bash
# Root users don't need to be in docker group - you can ignore this warning
# The warning is informational only for root users
```

**For non-root users - Manual fix:**
```bash
# Add your user to docker group (example with 'rangetech' user)
sudo usermod -aG docker rangetech

# Apply the group change immediately (alternative to logging out/in)
newgrp docker

# Test docker access
docker ps

# Alternative: Generic version for current user
sudo usermod -aG docker $USER
newgrp docker

# Log out and log back in, then verify
groups  # Should show 'docker' in the list
```

**Common Permission Error:**
```bash
# Error: permission denied while trying to connect to the Docker daemon socket
# Solution: Run the fix script or manual steps above
./fix-docker-permissions.sh
```

### **Verification Steps**
After applying any fix, verify with:
```bash
# Check what's available
podman-compose --version
podman compose --help
docker-compose --version

# Check the logs for more details
cat /tmp/easy_splunk_*.log

# Test the toolkit functionality
./function-loading-status.sh
```

---

## ⚙️ Configuration

- Config templates live in `./config-templates/`:
	- `development.conf` (local dev)
	- `small-production.conf`, `medium-production.conf`, `large-production.conf`
- Each template includes required Splunk sizing variables (e.g., `INDEXER_COUNT`, `SEARCH_HEAD_COUNT`, `CPU_INDEXER`, `MEMORY_INDEXER`, `CPU_SEARCH_HEAD`, `MEMORY_SEARCH_HEAD`) and common settings (e.g., `SPLUNK_DATA_DIR`, `SPLUNK_WEB_PORT`).
- You can deploy using a size keyword or a file:

```bash
# Use a template by size
./deploy.sh small

# Or pass a config file
./deploy.sh --config ./config-templates/small-production.conf

# Legacy alias also accepted
./deploy.sh --config-file ./config-templates/small-production.conf
```

Notes:
- Compose is generated automatically by `deploy.sh` via `lib/compose-generator.sh` into `./docker-compose.yml`. Avoid hand-editing; re-run deploy to regenerate.
- When `--with-monitoring` is used (or `ENABLE_MONITORING=true`), monitoring services are included in the generated compose, and default Prometheus/Grafana configs are written to `./config/`.
- Health checks honor your configured `SPLUNK_WEB_PORT` if set in `config/active.conf`.

---

## 🔑 Secrets & API Auth

Scripts that call the Splunk Management API use `curl -K` with a config file; secrets never appear in `ps` output.
- Dev default: `./secrets/curl_auth` (created by `generate-credentials.sh`, perms 600)
- Runtime: `/run/secrets/curl_auth` (mounted as a secret)

Example:

```bash
curl -sS -K /run/secrets/curl_auth https://localhost:8089/services/server/info -k
```

---

## 🖧 Ports & Endpoints

| Component        | Purpose        | Port | Notes                                          |
| ---------------- | -------------- | ---- | ---------------------------------------------- |
| Splunk Web       | UI             | 8000 | http://localhost:8000                          |
| Splunk Mgmt      | REST API       | 8089 | HTTPS only                                     |
| Search Head Cap. | Captain status | 8001 | Internal                                       |
| Prometheus       | Metrics        | 9090 | Optional                                       |
| Grafana          | Dashboards     | 3000 | Optional                                       |

---

## 🛡 SELinux & Firewall (RHEL/Fedora)

```bash
# Relabel volumes for container read/write
sudo ./generate-selinux-helpers.sh --apply

# Open firewall ports
sudo firewall-cmd --permanent --add-port=8000/tcp
sudo firewall-cmd --permanent --add-port=8089/tcp
sudo firewall-cmd --reload
```

---

## 📤 Air‑Gapped Deployment

On a connected build machine:

```bash
./resolve-digests.sh
./create-airgapped-bundle.sh
```

On the offline target:

```bash
tar -xzf splunk-cluster-airgapped-*.tar.gz
./verify-bundle.sh
./airgapped-quickstart.sh
```

Flow:
1) Resolve and pin image digests
2) Create bundle with checksums & manifest
3) Verify bundle on target
4) Load images and deploy

---

## 💾 Backup & Restore

```bash
# Backup (GPG-encrypted)
./backup_cluster.sh --recipient mykey@example.com

# Restore
./stop_cluster.sh
./restore_cluster.sh backup-YYYYMMDD.tar.gpg
./start_cluster.sh
```

Backups include configs, compose files, image digests, and data volumes.

---

## 🧪 Testing

```bash
./run_all_tests.sh
```

Test levels:
- Unit: validation logic, secret handling, runtime detection
- Integration: deploy lightweight test cluster, run health checks, tear down

---

## 🧹 Cleanup / Uninstall

```bash
./stop_cluster.sh

# Docker
docker compose down -v

# Podman
podman compose down -v
```

---

## 🧭 Deploy CLI (reference)

Common flags (subset):

```text
--config <file>           Load config (legacy: --config-file)
--with-monitoring         Enable Prometheus & Grafana
--no-monitoring           Disable monitoring
--index-name <name>       Create/configure Splunk index
--splunk-user <user>      Splunk admin user (default: admin)
--splunk-password <pass>  Prompted if omitted
--skip-creds              Skip credential generation
--skip-health             Skip post-deploy health check
--force                   Continue even if an existing cluster is detected
--debug                   Verbose logs

# Compatibility (no-op but accepted): --mode, --skip-digests
```

---

## 📄 License & Contributions

- MIT License (see LICENSE)
- Contributions welcome via pull requests
- For issues/feature requests, open a GitHub issue

