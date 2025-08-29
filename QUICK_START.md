# 🚀 Quick Start Guide

Get your Splunk cluster running in minutes with this streamlined guide. Perfect for first-time users and quick deployments.

---

## ⚠️ **CRITICAL FIRST STEP: Two-Part Installation Process**

**This is the most important part - do## �🔍 Troubleshooting Quick Reference

### *## �🔍 Troubleshooting Quick Reference

### **Most Common Issues**

| Issue | Symptom | Quick Fix |
|-------|---------|-----------|
| **Forgot to logout/login** | `docker: permission denied` | `exit` then log back in, run `./verify-installation.sh` |
| **Port 8000 already in use** | `Port already allocated` | `sudo lsof -ti:8000 \| xargs kill -9` |
| **Permission denied on files** | `Permission denied` | `sudo chown -R $USER:$USER .` |
| **Docker daemon not running** | `docker: command not found` or connection refused | `sudo systemctl start docker` |
| **Podman compose issues** | `podman-compose: command not found` | `./fix-podman-compose.sh` |
| **Python 3.6 errors (RHEL 8)** | `SyntaxError` in Python scripts | `./fix-python-compatibility.sh` |
| **CLI not executable** | `Permission denied` on bin/easy-splunk | `chmod +x bin/easy-splunk*` |
| **Old logs accumulating** | Disk space issues | `./rotate-logs.sh` |

### **Installation Issues**

| Issue | Check This |
|-------|------------|
| **"sudo not found"** | Install sudo: `apt-get install sudo` (Ubuntu/Debian) or `yum install sudo` (RHEL) |
| **"git not found"** | Install git: `apt-get install git` or `yum install git` |
| **"bash version too old"** | Upgrade bash or use a newer OS version |
| **Package manager errors** | Update package lists: `apt-get update` or `yum update` |

### **Post-Installation Issues**

| Issue | Solution |
|-------|----------|
| **Can't access Splunk Web** | Check if port 8000 is open: `netstat -tlnp \| grep 8000` |
| **Grafana login fails** | Default is admin/admin, change password immediately |
| **Prometheus not collecting metrics** | Check if services are running: `docker ps` |
| **SSL certificate errors** | Regenerate certificates: `./generate-credentials.sh` |

### **Getting Help**

```bash
# Check system health
./bin/easy-splunk health

# View detailed logs
./bin/easy-splunk logs

# Run diagnostics
./health_check.sh --verbose
```

**Still having issues?** Check our [Enhanced Error Handling Guide](ENHANCED_ERROR_HANDLING_GUIDE.md) or open an issue on GitHub.

## ✅ Validation Steps

After deployment, verify everything is working:

```bash
# Check cluster health
./bin/easy-splunk health

# Verify services are running
docker ps

# Check Splunk is accessible
curl -k https://localhost:8000

# Check Grafana is accessible
curl http://localhost:3000
```

## 🚨 Emergency Stop

If something goes wrong:

```bash
# Stop all services
./bin/easy-splunk stop

# Clean up everything
./bin/easy-splunk cleanup

# Start fresh
./bin/easy-splunk deploy --config config-templates/small-production.conf
```

---

**🎉 Success!** Your Splunk cluster is now running. Access it at:
- **Splunk Web**: https://localhost:8000
- **Grafana**: http://localhost:3000
- **Prometheus**: http://localhost:9090

**Need help?** Check the [full documentation](docs/) or open an issue on GitHub.sues**

| Issue | Symptom | Quick Fix |
|-------|---------|-----------|
| **Forgot to logout/login** | `docker: permission denied` | `exit` then log back in, run `./verify-installation.sh` |
| **Port 8000 already in use** | `Port already allocated` | `sudo lsof -ti:8000 \| xargs kill -9` |
| **Permission denied on files** | `Permission denied` | `sudo chown -R $USER:$USER .` |
| **Docker daemon not running** | `docker: command not found` or connection refused | `sudo systemctl start docker` |
| **Podman compose issues** | `podman-compose: command not found` | `./fix-podman-compose.sh` |
| **Python 3.6 errors (RHEL 8)** | `SyntaxError` in Python scripts | `./fix-python-compatibility.sh` |
| **CLI not executable** | `Permission denied` on bin/easy-splunk | `chmod +x bin/easy-splunk*` |
| **Old logs accumulating** | Disk space issues | `./rotate-logs.sh` |

### **Installation Issues**

| Issue | Check This |
|-------|------------|
| **"sudo not found"** | Install sudo: `apt-get install sudo` (Ubuntu/Debian) or `yum install sudo` (RHEL) |
| **"git not found"** | Install git: `apt-get install git` or `yum install git` |
| **"bash version too old"** | Upgrade bash or use a newer OS version |
| **Package manager errors** | Update package lists: `apt-get update` or `yum update` |

### **Post-Installation Issues**

| Issue | Solution |
|-------|----------|
| **Can't access Splunk Web** | Check if port 8000 is open: `netstat -tlnp \| grep 8000` |
| **Grafana login fails** | Default is admin/admin, change password immediately |
| **Prometheus not collecting metrics** | Check if services are running: `docker ps` |
| **SSL certificate errors** | Regenerate certificates: `./generate-credentials.sh` |

### **Getting Help**

```bash
# Check system health
./bin/easy-splunk health

# View detailed logs
./bin/easy-splunk logs

# Run diagnostics
./health_check.sh --verbose
```

**Still having issues?** Check our [Enhanced Error Handling Guide](ENHANCED_ERROR_HANDLING_GUIDE.md) or open an issue on GitHub.
The installation requires **two phases** due to Linux group membership limitations:

### **Phase 1: Install Prerequisites (2 minutes)**
```bash
# Clone the repository
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

# Install container runtime and dependencies (auto-detects your OS)
./install-prerequisites.sh --yes
```

**What this installs:**
- Docker or Podman (auto-selected based on your OS)
- Python 3 and pip3
- curl, jq, and other utilities
- Container compose tools

### **Phase 2: Logout/Login & Verify (30 seconds)**
```bash
# IMPORTANT: Log out and log back in for Docker group membership to take effect
exit
# (log back in to your system)

# Verify installation is complete
./verify-installation.sh
```

**Why is this required?**
- Phase 1 adds your user to the `docker` group
- Linux requires a new login session for group changes to take effect
- Phase 2 confirms everything works before deployment

### **⚠️ What happens if you skip logout/login?**

If you try to deploy without logging out and back in, you'll see errors like:
```
docker: permission denied while trying to connect to the Docker daemon socket
```

**Quick fix:** Exit your terminal, log back in, then run:
```bash
./verify-installation.sh && ./bin/easy-splunk deploy --config config-templates/small-production.conf
```

---

## ⚡ Deploy Small Profile with Monitoring (5 minutes)

### Option 1: Unified CLI (Recommended)
```bash
# Generate credentials and certificates
./bin/easy-splunk generate

# Deploy small production cluster with monitoring
./bin/easy-splunk deploy --config config-templates/small-production.conf
```

### Option 2: Individual Scripts (Legacy)
```bash
# Generate credentials and certificates
./generate-credentials.sh

# Deploy small production cluster with monitoring
./deploy.sh --config config-templates/small-production.conf
```

**What you get:**
- 2 Splunk Indexers + 1 Search Head cluster
- Prometheus + Grafana monitoring stack
- Auto-generated TLS certificates
- Management scripts for backup/restore

## � What to Expect During Installation

### **Phase 1 Output (install-prerequisites.sh)**
```
[INFO] Detected: ubuntu:24.04
[INFO] Installing Docker (preferred)...
[...installation output...]
[INFO] Adding boneysan to docker group...
[WARN] Group membership changed for user 'boneysan'. A new login session is required.
➡  Do one of the following:
   - **Recommended:** log out and back in, then run:
       ./verify-installation.sh && ./deploy.sh small --with-monitoring
   - **Or (same terminal, experimental):**
       sg docker -c './verify-installation.sh && ./deploy.sh small --with-monitoring'
```

### **Phase 2 Output (verify-installation.sh)**
```
[INFO] Container runtime detected: docker
[INFO] Docker daemon reachable
[INFO] docker compose available
All checks passed. You can deploy now.
```

## �🔐 Login Information

### Splunk Web Interface
- **URL**: `https://localhost:8000` (or your server's IP)
- **Username**: `admin`
- **Password**: Check `./credentials/splunk-admin-password.txt`

### Grafana Monitoring
- **URL**: `http://localhost:3000`
- **Username**: `admin`
- **Password**: `admin` (change immediately!)

### Prometheus Metrics
- **URL**: `http://localhost:9090`
- **No authentication required**

## ⚠️ Security First Steps

**Change default passwords immediately:**

```bash
# Splunk admin password
echo "NewSecurePassword123!" > ./credentials/splunk-admin-password.txt
./generate-credentials.sh  # Regenerates with new password

# Grafana admin password (login first, then change in UI)
# 1. Visit http://localhost:3000
# 2. Login with admin/admin
# 3. Go to Configuration → Users → admin → Edit Profile
# 4. Change password to something secure
```

## � Unified CLI Tools

The toolkit provides unified CLI entry points for simplified operations:

### Main CLI (`bin/easy-splunk`)
```bash
# Deploy cluster
./bin/easy-splunk deploy --config config-templates/small-production.conf

# Create air-gapped bundle
./bin/easy-splunk airgap --output my-bundle.tar.gz

# Backup cluster
./bin/easy-splunk backup --output backup-2025-08-29.tar.gz

# Check health
./bin/easy-splunk health

# View logs
./bin/easy-splunk logs

# Stop cluster
./bin/easy-splunk stop

# Clean up resources
./bin/easy-splunk cleanup
```

### Specialized CLIs
```bash
# Air-gapped bundle creation
./bin/easy-splunk-airgap --resolve-digests --verify

# Backup and restore operations
./bin/easy-splunk-backup list
./bin/easy-splunk-backup cleanup --older-than 30
```

## �📊 Verify Your Deployment

```bash
# Check cluster health (unified CLI)
./bin/easy-splunk health

# Or use individual script
./health_check.sh

# View monitoring dashboards
open http://localhost:3000  # Grafana
open https://localhost:8000  # Splunk
```

## 🛠️ Common Next Steps

### Using Unified CLI (Recommended)
```bash
# Scale up your cluster
./bin/easy-splunk deploy --config config-templates/medium-production.conf

# Enable air-gapped mode
./bin/easy-splunk airgap

# Backup your configuration
./bin/easy-splunk backup

# Monitor system resources
./bin/easy-splunk deploy --monitoring
```

### Using Individual Scripts (Legacy)
```bash
# Scale up your cluster
./deploy.sh --config config-templates/medium-production.conf

# Enable air-gapped mode
./airgapped-quickstart.sh

# Backup your configuration
./backup_cluster.sh

# Monitor system resources
./monitoring/start-monitoring.sh
```

## 🚨 Having Issues?

Jump to our [Enhanced Error Handling Guide](ENHANCED_ERROR_HANDLING_GUIDE.md) for:
- Container runtime problems
- Network connectivity issues
- Permission errors
- Python compatibility fixes

## 📚 Advanced Configuration

- **Large Production**: `config-templates/large-production.conf`
- **Development**: `config-templates/development.conf`
- **Custom Setup**: Edit any `.conf` file in `config-templates/`

## � Maintenance & Monitoring

### Log Management
```bash
# Rotate and clean up old logs automatically
./rotate-logs.sh

# View recent logs
./bin/easy-splunk logs

# Check system health
./bin/easy-splunk health
```

### Backup Operations
```bash
# Create backup (unified CLI)
./bin/easy-splunk backup --output my-backup.tar.gz

# List available backups
./bin/easy-splunk-backup list

# Clean old backups
./bin/easy-splunk-backup cleanup --older-than 30

# Restore from backup
./bin/easy-splunk-backup restore my-backup.tar.gz
```

## �🔍 Troubleshooting Quick Reference

| Issue | Quick Fix |
|-------|-----------|
| Port 8000 already in use | `sudo lsof -ti:8000 \| xargs kill -9` |
| Permission denied | `sudo chown -R $USER:$USER .` |
| Docker not starting | `sudo systemctl start docker` |
| Podman compose issues | `./fix-podman-compose.sh` |
| Python 3.6 errors (RHEL 8) | `./fix-python-compatibility.sh` |
| CLI not found | `chmod +x bin/easy-splunk*` |
| Old logs accumulating | `./rotate-logs.sh` |

---

**Need help?** Check the [full documentation](docs/) or open an issue on GitHub.
