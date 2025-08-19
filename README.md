# Easy_Splunk

A comprehensive shell-based orchestration toolkit for deploying, managing, and securing a containerized Splunk cluster on Docker or Podman.  
Supports air-gapped environments, automated credential/TLS generation, integrated monitoring (Prometheus + Grafana), and hardened RHEL/Fedora deployments.

**✅ Latest Update**: Fixed container runtime detection for RHEL 8, CentOS 8, Rocky Linux, and other enterprise distributions.

---

# Easy_Splunk

A shell-based orchestration toolkit for deploying, managing, and securing a containerized Splunk cluster on Docker or Podman. Supports air‑gapped installs, automated credentials/TLS, and optional monitoring (Prometheus + Grafana).

---

## 📐 Architecture Overview

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
- ✅ **RHEL 8+** (Red Hat Enterprise Linux)
- ✅ **CentOS 8+** / **Rocky Linux 8+** / **AlmaLinux 8+**
- ✅ **Ubuntu 20.04+** / **Debian 10+**
- ✅ **Fedora 35+**
- ✅ **WSL2** (Windows Subsystem for Linux)

### **Installation Steps**

```bash
# 1) Clone and enter
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

# 2) Install prerequisites (automatically detects OS and installs container runtime)
./install-prerequisites.sh --yes

# 3) Generate credentials (admin user/secret, TLS as needed)
./generate-credentials.sh

# 4) Deploy a small cluster with monitoring
./deploy.sh small --with-monitoring

# 5) Health check
./health_check.sh
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

