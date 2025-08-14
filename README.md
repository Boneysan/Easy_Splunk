# Easy Splunk – Cluster Orchestrator

## 📦 Overview
Easy Splunk automates the deployment, management, and maintenance of a containerized Splunk cluster with optional monitoring (Prometheus + Grafana). It supports small, medium, and large cluster sizes, works with Docker or Podman, and includes scripts for credential generation, configuration, health checks, backups, restores, API management, bundle verification, digest resolution, and legacy configuration migration.

## 📜 Architecture
The deployment consists of a multi-node Splunk cluster, an optional monitoring stack, and supporting utilities for management and maintenance.

             ┌───────────────────────┐
             │       Users / Apps     │
             └───────────┬────────────┘
                         │
             ┌───────────▼───────────┐
             │     Search Head(s)     │
             │     (Captain) :8001    │
             └───────────┬───────────┘
                         │
  ┌──────────────────────▼─────────────────────┐
  │          Cluster Master (License) :8000    │
  └───────────┬────────────────────────────────┘
              │
  ┌───────────▼───────────┐     ┌───────────────┐
  │     Indexer Cluster   │     │ Monitoring    │
  │  idx1   idx2   idx3   │     │ Prom:9090     │
  │                       │     │ Graf:3000     │
  └───────────────────────┘     └───────────────┘


## 🚀 Quick Start (Recommended)
This two-step process deploys a medium-sized Splunk cluster with monitoring.

```bash
# 1. Clone the repo and enter the directory
git clone https://github.com/example/Easy_Splunk.git
cd Easy_Splunk

# 2. Install prerequisites and deploy
./install-prerequisites.sh && \
./deploy.sh medium --index-name my_app_prod --splunk-user admin

Once deployed, services are available at:

Splunk Web UI: http://localhost:8000
Prometheus: http://localhost:9090 (if enabled)
Grafana: http://localhost:3000 (if enabled)

🛠️ Deploy with Wrapper
The deploy.sh script automates credential generation, configuration, index creation, and deployment.
./deploy.sh <small|medium|large|/path/to/conf> [options]

Options



Flag
Description
Default



--index-name <NAME>
Creates and configures the specified index in Splunk
(none)


--splunk-user <USER>
Splunk admin username
admin


--splunk-password <PASS>
Splunk admin password
(prompt)


--no-monitoring
Disables Prometheus + Grafana
(enabled if in config)


--skip-creds
Skips credential generation to reuse existing ones



--skip-health
Skips post-deployment health check



Examples
# Deploy a large cluster without monitoring
./deploy.sh large --no-monitoring

# Use a custom config file and create an index
./deploy.sh ./config-templates/custom.conf --index-name stage_index

⚙️ Cluster Sizing & Configs
Cluster size and resource allocations are defined in .conf files in config-templates/.



Size
Indexers
Search Heads
Indexer CPU/Mem
Search Head CPU/Mem
Best For



Small
2
1
2 vCPU / 4 GB
1 vCPU / 2 GB
Light production


Medium
3
1
4 vCPU / 8 GB
2 vCPU / 4 GB
Mid-size workloads


Large
5
2
8 vCPU / 16 GB
4 vCPU / 8 GB
Heavy ingest / high availability


Config Examples

Small (small-production.conf)

# config-templates/small-production.conf
INDEXER_COUNT=2
SEARCH_HEAD_COUNT=1
ENABLE_MONITORING=true
CPU_INDEXER="2"
MEMORY_INDEXER="4G"
CPU_SEARCH_HEAD="1"
MEMORY_SEARCH_HEAD="2G"




Medium (medium-production.conf)

# config-templates/medium-production.conf
INDEXER_COUNT=3
SEARCH_HEAD_COUNT=1
ENABLE_MONITORING=true
CPU_INDEXER="4"
MEMORY_INDEXER="8G"
CPU_SEARCH_HEAD="2"
MEMORY_SEARCH_HEAD="4G"




Large (large-production.conf)

# config-templates/large-production.conf
INDEXER_COUNT=5
SEARCH_HEAD_COUNT=2
ENABLE_MONITORING=true
CPU_INDEXER="8"
MEMORY_INDEXER="16G"
CPU_SEARCH_HEAD="4"
MEMORY_SEARCH_HEAD="8G"



📋 Manual Deployment (Advanced)
For granular control, run scripts individually.
1. Prerequisites

OS: RHEL/CentOS/Rocky/Fedora, Debian/Ubuntu, macOS
Tools: git, bash ≥ 4.0, sudo, Docker or Podman

2. Clone Repo
git clone https://github.com/example/Easy_Splunk.git
cd Easy_Splunk

3. Install Container Runtime
./install-prerequisites.sh

4. Configure SELinux (RHEL-based)
sudo ./generate-selinux-helpers.sh

5. Resolve Image Digests
Pin image tags to immutable digests in versions.env:
./resolve-digests.sh

6. Generate Credentials
yes | ./generate-credentials.sh

7. Generate Monitoring Config
yes | ./generate-monitoring-config.sh

8. Select Config
cp config-templates/small-production.conf config/active.conf

9. Configure Splunk Index and HEC
./generate-splunk-configs.sh --index-name manual_index --splunk-user admin

10. Deploy Cluster
./orchestrator.sh --with-monitoring

11. Check Health
./health_check.sh

12. Manage via API
Generate API management scripts:
./generate-management-scripts.sh

Use generated scripts:
./management-scripts/get-health.sh
./management-scripts/list-users.sh
./management-scripts/add-user.sh testuser testpass admin

13. Backup and Restore
Backup the cluster:
./backup_cluster.sh --output-dir ./backups --gpg-recipient ops@example.com

Restore from backup:
./restore_cluster.sh --backup-file ./backups/backup-20250101-120000.tar.gz.gpg --rollback-gpg-recipient ops@example.com

14. Verify Air-Gapped Bundle
Verify a bundle for air-gapped deployment:
./verify-bundle.sh ./app-bundle-v3.5.1-20250101.tar.gz

15. Air-Gapped Deployment
Create and deploy an air-gapped bundle:
./create-airgapped.sh
./airgapped-quickstart.sh

16. Migrate Legacy Configuration
Check a v2.0 configuration for migration issues:
./integration-guide.sh ./old.env --output markdown --report migration_report.md

17. Stop Cluster
./stop_cluster.sh

🧪 Running Tests
The project includes a comprehensive test suite with unit and integration tests.
Run All Tests
./run_all_tests.sh

Run Unit Tests Only
./run_all_tests.sh --unit-only

Run Integration Tests Only
./run_all_tests.sh --integration-only

Filter Tests
./run_all_tests.sh --filter validation

Verbose Output
./run_all_tests.sh --verbose

Note: Integration tests (test_full_deployment.sh, test_deploy.sh) require a running Docker/Podman environment and sufficient system resources.
🔒 Security Considerations

Secure File Handling: Scripts use security.sh for auditing permissions (audit_security_configuration) and securing files (harden_file_permissions).
Credential Management: Credentials are stored in ${SECRETS_DIR} (default: ./secrets) with restrictive permissions.
Encrypted Backups: backup_cluster.sh and restore_cluster.sh support GPG encryption.
API Security: generate-management-scripts.sh loads API keys at runtime from secure .env files.
Bundle Verification: verify-bundle.sh checks for sensitive files and validates checksums.

🐛 Troubleshooting
Docker Permission Denied
sudo usermod -aG docker $USER

Log out and back in for changes to take effect.
SELinux Volume Errors
sudo ./generate-selinux-helpers.sh

Check Service Health
./health_check.sh
docker compose logs <service_name>

Failed Tests
Run with verbose output to debug:
./run_all_tests.sh --verbose

📌 Notes for RHEL 8 ARM

Works if container images exist for linux/arm64.
Podman is recommended; ensure podman-compose supports ARM.
Rebuild Splunk images if official ARM builds are unavailable.


