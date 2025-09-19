# 🚀 Quick Start Guide

Get your Splunk cluster running in minutes with this streamlined guide. Perfect for first-time users and quick deployments.

---

## ⚠️ **CRITICAL FIRST STEP: Two-Part Installation Process**

**This is the most important part - don't skip it!**

The installation requires **two phases** due to Linux group membership limitations:

### **Phase 1: Install Prerequisites (2 minutes)**
```bash
# Clone the repository
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

# Install container runtime and dependencies (auto-detects your OS)
# --yes flag automatically accepts all prompts (recommended for automation)
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

# Verify installation is complete (no sudo needed after logout/login)
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

## ⚡ Deploy Small Production Cluster (5 minutes)

### **Method 1: Unified CLI (Recommended)**
```bash
# Generate credentials and certificates first
./bin/easy-splunk generate

# Deploy small production cluster with monitoring
./bin/easy-splunk deploy --config config-templates/small-production.conf
```

### **Method 2: Step-by-Step with Individual Scripts**
```bash
# Generate credentials and certificates
./generate-credentials.sh

# Deploy small production cluster
./deploy.sh --config config-templates/small-production.conf
```

### **Method 3: Using Default Configuration**
```bash
# Use the default active configuration (simpler)
./bin/easy-splunk generate
./bin/easy-splunk deploy
```

**What you get:**
- 2 Splunk Indexers + 1 Search Head cluster
- Prometheus + Grafana monitoring stack
- Auto-generated TLS certificates
- Management scripts for backup/restore

## 📋 What to Expect During Installation

### **Phase 1 Output (install-prerequisites.sh)**
```
[INFO] Detected: ubuntu:24.04
[INFO] Installing Docker (preferred)...
[...installation output...]
[INFO] Adding rangetech to docker group...
[WARN] Group membership changed for user 'rangetech'. A new login session is required.
➡  Do one of the following:
   - **Recommended:** log out and back in, then run:
       ./verify-installation.sh && ./bin/easy-splunk deploy
   - **Or (same terminal, experimental):**
       sg docker -c './verify-installation.sh && ./bin/easy-splunk deploy'
```

### **Phase 2 Output (verify-installation.sh)**
```
[INFO] Container runtime detected: docker
[INFO] Docker daemon reachable
[INFO] docker compose available
All checks passed. You can deploy now.
```

### **Deployment Output**
```
[INFO] Generating Splunk credentials...
[INFO] Creating docker-compose.yml from template...
[INFO] Starting Splunk cluster...
[INFO] Cluster deployed successfully!
```

## 🔐 Login Information

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
# Splunk admin password (update before generating credentials)
echo "NewSecurePassword123!" > ./credentials/splunk-admin-password.txt
./bin/easy-splunk generate  # Regenerates with new password

# Grafana admin password (after first login)
# 1. Visit http://localhost:3000
# 2. Login with admin/admin
# 3. Go to Configuration → Users → admin → Change Password
# 4. Set a secure password
```

## 🛠️ Unified CLI Tools

The toolkit provides unified CLI entry points for simplified operations:

### **Main CLI (`bin/easy-splunk`)**
```bash
# Basic deployment
./bin/easy-splunk deploy

# Deploy with specific configuration
./bin/easy-splunk deploy --config config-templates/small-production.conf

# Deploy with monitoring enabled
./bin/easy-splunk deploy --monitoring

# Create air-gapped bundle
./bin/easy-splunk airgap --output my-bundle.tar.gz

# Backup cluster
./bin/easy-splunk backup --output backup-$(date +%Y-%m-%d).tar.gz

# Check health
./bin/easy-splunk health

# View logs
./bin/easy-splunk logs

# Stop cluster
./bin/easy-splunk stop

# Clean up resources
./bin/easy-splunk cleanup
```

### **Specialized CLIs**
```bash
# Air-gapped bundle creation
./bin/easy-splunk-airgap --resolve-digests --verify

# Backup and restore operations
./bin/easy-splunk-backup list
./bin/easy-splunk-backup cleanup --older-than 30
```

## 📊 Verify Your Deployment

```bash
# Check cluster health (unified CLI)
./bin/easy-splunk health

# Or use individual health check script
./health_check.sh

# Verify services are running
docker ps

# Check web interfaces
curl -k https://localhost:8000  # Splunk (ignore SSL warnings)
curl http://localhost:3000      # Grafana
curl http://localhost:9090      # Prometheus
```

## � Common Next Steps

### **Scale Up Your Cluster**
```bash
# Medium production cluster (more indexers)
./bin/easy-splunk deploy --config config-templates/medium-production.conf

# Large production cluster (enterprise-scale)
./bin/easy-splunk deploy --config config-templates/large-production.conf
```

### **Air-Gapped Deployment**
```bash
# Create bundle for offline installation
./bin/easy-splunk airgap --output offline-bundle.tar.gz

# Deploy from bundle (on air-gapped system)
./airgapped-quickstart.sh offline-bundle.tar.gz
```

### **Backup and Monitoring**
```bash
# Regular backup
./bin/easy-splunk backup --output daily-backup.tar.gz

# Monitor system resources
./monitoring/start-monitoring.sh
```

## � Configuration Options

### **Available Templates**
- **Development**: `config-templates/development.conf` - Minimal resources for testing
- **Small Production**: `config-templates/small-production.conf` - 2 indexers, basic monitoring
- **Medium Production**: `config-templates/medium-production.conf` - 4 indexers, enhanced monitoring  
- **Large Production**: `config-templates/large-production.conf` - 8+ indexers, full enterprise features

### **Configuration Paths**
```bash
# Default active configuration (recommended for most users)
./bin/easy-splunk deploy

# Specific template configuration  
./bin/easy-splunk deploy --config config-templates/small-production.conf

# Custom configuration (copy and modify a template)
cp config-templates/small-production.conf my-custom.conf
# Edit my-custom.conf as needed
./bin/easy-splunk deploy --config my-custom.conf
```

## 🔧 Maintenance & Monitoring

### **Log Management**
```bash
# Rotate and clean up old logs automatically
./rotate-logs.sh

# View recent logs
./bin/easy-splunk logs

# Check system health
./bin/easy-splunk health

# Detailed diagnostics
./health_check.sh --verbose
```

### **Backup Operations**
```bash
# Create backup (unified CLI)
./bin/easy-splunk backup --output my-backup-$(date +%Y%m%d).tar.gz

# List available backups
./bin/easy-splunk-backup list

# Clean old backups (older than 30 days)
./bin/easy-splunk-backup cleanup --older-than 30

# Restore from backup
./bin/easy-splunk-backup restore my-backup-20250919.tar.gz
```

## 🔍 Troubleshooting Quick Reference

### **Most Common Issues**

| Issue | Symptom | Quick Fix |
|-------|---------|-----------|
| **Forgot to logout/login** | `docker: permission denied` | `exit` then log back in, run `./verify-installation.sh` |
| **CLI not executable** | `Permission denied` on bin/easy-splunk | `chmod +x bin/easy-splunk*` |
| **Port 8000 already in use** | `Port already allocated` | `sudo lsof -ti:8000 \| xargs kill -9` |
| **Permission denied on files** | `Permission denied` | `sudo chown -R $USER:$USER .` |
| **Docker daemon not running** | `docker: command not found` or connection refused | `sudo systemctl start docker` |
| **Podman compose issues** | `podman-compose: command not found` | `./fix-podman-compose.sh` |
| **Python 3.6 errors (RHEL 8)** | `SyntaxError` in Python scripts | `./fix-python-compatibility.sh` |
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

# Check Prometheus is accessible
curl http://localhost:9090
```

## 🚨 Emergency Stop

If something goes wrong:

```bash
# Stop all services
./bin/easy-splunk stop

# Clean up everything (removes containers and volumes)
./bin/easy-splunk cleanup

# Start fresh
./bin/easy-splunk deploy --config config-templates/small-production.conf
```

## 🎯 Having Issues?

For complex problems, check our comprehensive guides:
- [Enhanced Error Handling Guide](ENHANCED_ERROR_HANDLING_GUIDE.md) - Detailed troubleshooting
- [Docker/Podman Guide](DOCKER_PODMAN_GUIDE.md) - Container runtime issues
- [Development Summary](DEVELOPMENT_SUMMARY.md) - Advanced configuration

---

**🎉 Success!** Your Splunk cluster is now running. Access it at:
- **Splunk Web**: https://localhost:8000 (admin/[check credentials/splunk-admin-password.txt])
- **Grafana**: http://localhost:3000 (admin/admin - change immediately!)
- **Prometheus**: http://localhost:9090 (no auth required)

**Need help?** Check the [full documentation](docs/) or open an issue on [GitHub](https://github.com/Boneysan/Easy_Splunk).
