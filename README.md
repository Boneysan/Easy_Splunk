Here’s the **complete, unified README** you asked for — I’ve merged the Quick Start, Installation Guide, Troubleshooting section, and your configuration templates into one cohesive document. Everything is in one place with no redundancy, and I’ve embedded an **ASCII architecture diagram** for a clean GitHub-friendly view.

---

# **App Cluster Orchestrator**

A comprehensive, shell-based toolkit for deploying, managing, and securing a containerized application stack with Docker or Podman.

This project automates everything from initial setup and configuration to ongoing operations like monitoring, backups, and security management. It’s designed for flexibility, reliability, and ease of use in both development and production environments.

---

## **⭐ Features**

* 🚀 **Automated Deployment:** Single `orchestrator.sh` command for complete stack setup.
* 🐳 **Flexible Runtimes:** Supports **Docker** and **Podman** with auto-detection.
* 🔒 **Built-in Security:** Automatic credentials and self-signed TLS generation.
* 📊 **Integrated Monitoring:** One-flag setup for Prometheus & Grafana dashboards.
* ✈️ **Air-Gapped Support:** Create offline-ready bundles with SHA256 verification.
* 🛡️ **RHEL Ready:** SELinux and `firewalld` helper scripts for RHEL/CentOS/Fedora.
* ❤️ **Robust Health Checks:** Integrated script for verifying service health and resources.
* 📦 **Backup & Restore:** GPG-encrypted disaster recovery.

---

## **📦 Architecture Diagram (ASCII)**

```
                      ┌──────────────────────────┐
                      │       Users / Apps        │
                      └──────────────┬────────────┘
                                     │
                        ┌────────────▼────────────┐
                        │    Main Application     │ :8080 / :80
                        └────────────┬────────────┘
                                     │
             ┌───────────────────────┼───────────────────────┐
             │                       │                       │
┌────────────▼────────────┐   ┌──────▼───────────┐   ┌───────▼─────────┐
│        Redis Cache      │   │   Prometheus     │   │    Grafana      │
│   :6379                 │   │   :9090          │   │    :3000        │
└─────────────────────────┘   └──────────────────┘   └─────────────────┘
```

---

## **1. Prerequisites**

* **OS:** RHEL/CentOS/Rocky/Fedora, Debian/Ubuntu, or macOS
* **Tools:** `git`, `bash` ≥4.0, `sudo` privileges
* **Internet connection** (for first install; optional offline bundle later)

---

## **2. Installation**

### **Clone the Repository**

```bash
git clone https://github.com/example/app-cluster-orchestrator.git
cd app-cluster-orchestrator
```

### **Install Container Runtime**

**Easy Way (Recommended):**

```bash
./install-prerequisites.sh
```

**Manual:**

* **RHEL/Fedora**: `sudo dnf install -y podman podman-compose podman-docker`
* **Debian/Ubuntu**: `sudo apt-get install -y docker.io docker-compose`
* **macOS**: `brew install --cask docker`

### **RHEL-Specific SELinux/Firewall Config**

```bash
sudo ./generate-selinux-helpers.sh
```

---

## **3. Cluster Sizing & Configuration**

Choose a config template based on your use case. Copy it to `cluster_config.env` before running `orchestrator.sh`.

### **development.conf**

```bash
ENABLE_MONITORING="true"
GENERATE_MGMT_SCRIPTS="false"
APP_PORT="8080"
DATA_DIR="./dev-data"
APP_CPU_LIMIT="1"
APP_MEM_LIMIT="1G"
```

### **small-production.conf**

```bash
ENABLE_MONITORING="true"
GENERATE_MGMT_SCRIPTS="true"
APP_PORT="80"
DATA_DIR="/var/lib/my-app"
APP_CPU_LIMIT="2"
APP_MEM_LIMIT="4G"
REDIS_CPU_LIMIT="0.5"
REDIS_MEM_LIMIT="1G"
PROMETHEUS_CPU_LIMIT="1"
PROMETHEUS_MEM_LIMIT="1G"
GRAFANA_CPU_LIMIT="0.5"
GRAFANA_MEM_LIMIT="512M"
```

### **medium-production.conf**

```bash
ENABLE_MONITORING="true"
GENERATE_MGMT_SCRIPTS="true"
APP_PORT="80"
DATA_DIR="/var/lib/my-app"
APP_CPU_LIMIT="4"
APP_MEM_LIMIT="8G"
REDIS_CPU_LIMIT="1"
REDIS_MEM_LIMIT="2G"
PROMETHEUS_CPU_LIMIT="1.5"
PROMETHEUS_MEM_LIMIT="2G"
GRAFANA_CPU_LIMIT="1"
GRAFANA_MEM_LIMIT="1G"
```

### **large-production.conf**

```bash
ENABLE_MONITORING="true"
GENERATE_MGMT_SCRIPTS="true"
APP_PORT="80"
DATA_DIR="/var/lib/my-app"
APP_CPU_LIMIT="8"
APP_MEM_LIMIT="16G"
REDIS_CPU_LIMIT="2"
REDIS_MEM_LIMIT="4G"
PROMETHEUS_CPU_LIMIT="2"
PROMETHEUS_MEM_LIMIT="4G"
GRAFANA_CPU_LIMIT="1"
GRAFANA_MEM_LIMIT="1G"
```

---

## **4. Deployment**

```bash
# Generate credentials
yes | ./generate-credentials.sh

# Deploy with chosen config
cp config-templates/medium-production.conf cluster_config.env
./orchestrator.sh

# Optional: enable monitoring explicitly
./orchestrator.sh --with-monitoring
```

---

## **5. Verification**

```bash
./health_check.sh
```

* App: [http://localhost:8080](http://localhost:8080) (or port from config)
* Grafana: [http://localhost:3000](http://localhost:3000)
* Prometheus: [http://localhost:9090](http://localhost:9090)

---

## **6. Advanced Usage**

* **Air-Gapped Deployments:**

  1. `./resolve-digests.sh`
  2. `./create-airgapped-bundle.sh`
  3. Transfer and `./airgapped-quickstart.sh`
* **Backup/Restore:**

  * Backup: `./backup_cluster.sh --output-dir /path/to/backups --gpg-recipient "key_id"`
  * Restore: `./restore_cluster.sh --backup-file backup.tar.gz.gpg --rollback-gpg-recipient "key_id"`

---

## **7. Troubleshooting**

**Docker Permission Denied:**

```bash
sudo usermod -aG docker $USER
```

(Log out & back in)

**SELinux Volume Access Denied:**

```bash
sudo ./generate-selinux-helpers.sh
```

**Compose Command Not Found:**
Ensure `docker-compose` or `podman-compose` is installed.

**App Not Reachable:**

```bash
./health_check.sh
docker compose logs <service>
```

---

## **📜 License**

MIT License

---

If you want, I can also **link the configuration templates to auto-load with `--size small|medium|large|dev` flags in orchestrator.sh**, so users won’t need to copy files manually. That would make deployment even smoother.

Do you want me to implement that next?
