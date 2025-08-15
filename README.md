```markdown
# Easy_Splunk

A comprehensive shell-based orchestration toolkit for deploying, managing, and securing a containerized Splunk cluster on Docker or Podman.  
Supports air-gapped environments, automated credential/TLS generation, integrated monitoring (Prometheus + Grafana), and hardened RHEL/Fedora deployments.

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

````

---

## 🚀 Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

# 2. Install prerequisites
./install-prerequisites.sh

# 3. Generate credentials & TLS
./generate-credentials.sh

# 4. Deploy (example: small config with monitoring)
./deploy.sh small --with-monitoring

# 5. Check health
./health_check.sh
````

---

## 📦 Manual Deployment

```bash
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

./install-prerequisites.sh
./generate-credentials.sh

# Optional: adjust ./config-templates/*.conf or pass custom config
./deploy.sh ./my-config.conf
```

---

## 🔑 Secrets & API Auth (No Passwords in `ps`)

All scripts that call the Splunk Management API use a `curl -K` config file instead of `-u user:pass`, so secrets never appear in process lists.

* **Dev default:** `./secrets/curl_auth` (created by `generate-credentials.sh`, perms 600)
* **Compose runtime:** `/run/secrets/curl_auth` (mounted as a secret)

Example usage:

```bash
curl -sS -K /run/secrets/curl_auth https://localhost:8089/services/server/info -k
```

If you find any `curl -u admin:$SPLUNK_PASSWORD` patterns left in scripts, open an issue — those are considered bugs.

---

## 🖧 Ports & Endpoints

| Component        | Purpose        | Port | Notes                                          |
| ---------------- | -------------- | ---- | ---------------------------------------------- |
| Splunk Web       | UI             | 8000 | [http://localhost:8000](http://localhost:8000) |
| Splunk Mgmt      | REST API       | 8089 | HTTPS only                                     |
| Search Head Cap. | Captain status | 8001 | Internal                                       |
| Prometheus       | Metrics        | 9090 | Optional                                       |
| Grafana          | Dashboards     | 3000 | Optional                                       |

---

## 🛡 SELinux & Firewall Notes (RHEL/Fedora)

On SELinux-enabled systems, you may need to relabel volumes and open ports:

```bash
# Label volumes for container read/write
sudo ./generate-selinux-helpers.sh --apply

# Open firewall ports
sudo firewall-cmd --permanent --add-port=8000/tcp
sudo firewall-cmd --permanent --add-port=8089/tcp
sudo firewall-cmd --reload
```

---

## 📤 Air-Gapped Deployment

**Connected build machine:**

```bash
./resolve-digests.sh
./create-airgapped-bundle.sh
```

**Offline target:**

```bash
tar -xzf splunk-cluster-airgapped-*.tar.gz
./verify-bundle.sh
./airgapped-quickstart.sh
```

**Flow checklist:**

1. Resolve and pin image digests.
2. Create bundle with checksums & manifest.
3. Verify bundle on target.
4. Load images, deploy cluster.

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

Run all tests:

```bash
./run_all_tests.sh
```

Test levels:

* **Unit:** Validation logic, secret handling, runtime detection.
* **Integration:** Deploy lightweight test cluster, run health checks, tear down.

---

## 🧹 Cleanup / Uninstall

```bash
# Stop services
./stop_cluster.sh

# Remove containers & volumes (Docker)
docker compose down -v

# Or with Podman
podman compose down -v
```

---

## 📄 License & Contributions

* Licensed under the MIT License (see LICENSE file).
* Contributions welcome via pull requests.
* For issues and feature requests, please open a ticket in the GitHub Issues tab.

---

```

