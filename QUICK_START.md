# 🚀 Quick Start Guide

Get your Splunk cluster running in minutes with this streamlined guide. Perfect for first-time users and quick deployments.

## 📋 Prerequisites (2 minutes)

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

## ⚡ Deploy Small Profile with Monitoring (5 minutes)

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
# Splunk admin password
echo "NewSecurePassword123!" > ./credentials/splunk-admin-password.txt
./generate-credentials.sh  # Regenerates with new password

# Grafana admin password (login first, then change in UI)
# 1. Visit http://localhost:3000
# 2. Login with admin/admin
# 3. Go to Configuration → Users → admin → Edit Profile
# 4. Change password to something secure
```

## 📊 Verify Your Deployment

```bash
# Check cluster health
./health_check.sh

# View monitoring dashboards
open http://localhost:3000  # Grafana
open https://localhost:8000  # Splunk
```

## 🛠️ Common Next Steps

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

## 🔍 Troubleshooting Quick Reference

| Issue | Quick Fix |
|-------|-----------|
| Port 8000 already in use | `sudo lsof -ti:8000 \| xargs kill -9` |
| Permission denied | `sudo chown -R $USER:$USER .` |
| Docker not starting | `sudo systemctl start docker` |
| Podman compose issues | `./fix-podman-compose.sh` |
| Python 3.6 errors (RHEL 8) | `./fix-python-compatibility.sh` |

---

**Need help?** Check the [full documentation](docs/) or open an issue on GitHub.
