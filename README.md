Here's the finalized README, incorporating all the updates with improved formatting for clarity.

Easy Splunk – Cluster Orchestrator
📦 Overview
Easy Splunk automates the deployment of a containerized Splunk cluster with optional monitoring (Prometheus + Grafana). It supports small, medium, and large cluster sizes, works on Docker or Podman, and ships with scripts for credentials, configs, health checks, and teardown.

📜 Architecture
The deployment consists of a multi-node Splunk cluster and an optional monitoring stack.

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
🚀 Quick Start (Recommended)
This two-step process gets you up and running with a medium-sized cluster.

Bash

# 1. Clone the repo and enter the directory
git clone https://github.com/example/Easy_Splunk.git
cd Easy_Splunk

# 2. Install prerequisites and deploy
./install-prerequisites.sh && \
./deploy.sh medium --index-name my_app_prod --splunk-user admin
Once deployed, the services are available at:

Splunk Web UI: http://localhost:8000

Prometheus: http://localhost:9090 (if enabled)

Grafana: http://localhost:3000 (if enabled)

🛠️ Deploy with Wrapper
The deploy.sh script is the easiest way to manage deployments. It automates credential generation, configuration, and deployment.

Bash

./deploy.sh <small|medium|large|/path/to/conf> [options]
Options
Flag	Description	Default
--index-name <NAME>	Creates and configures the specified index in Splunk.	(none)
--splunk-user <USER>	The Splunk admin username.	admin
--splunk-password <PASS>	The Splunk admin password.	(prompt)
--no-monitoring	Disables Prometheus + Grafana, even if enabled in the config.	
--skip-creds	Skips credential generation to reuse existing ones.	
--skip-health	Skips the post-deployment health check.	

Export to Sheets
Examples
Bash

# Deploy a large cluster without the monitoring stack
./deploy.sh large --no-monitoring

# Use a custom config file and create an index
./deploy.sh ./config-templates/custom.conf --index-name stage_index
⚙️ Cluster Sizing & Configs
The cluster size and resource allocations are defined in .conf files located in config-templates/.

Size	Indexers	Search Heads	Indexer CPU / Mem	Search Head CPU / Mem	Best For
Small	2	1	2 vCPU / 4 GB	1 vCPU / 2 GB	Light production
Medium	3	1	4 vCPU / 8 GB	2 vCPU / 4 GB	Mid-size workloads
Large	5	2	8 vCPU / 16 GB	4 vCPU / 8 GB	Heavy ingest / high availability

Export to Sheets
Config Examples
<details>
<summary><strong>Small (small-production.conf)</strong></summary>

Bash

# config-templates/small-production.conf
INDEXER_COUNT=2
SEARCH_HEAD_COUNT=1
ENABLE_MONITORING=true
CPU_INDEXER="2"
MEMORY_INDEXER="4G"
CPU_SEARCH_HEAD="1"
MEMORY_SEARCH_HEAD="2G"
</details>

<details>
<summary><strong>Medium (medium-production.conf)</strong></summary>

Bash

# config-templates/medium-production.conf
INDEXER_COUNT=3
SEARCH_HEAD_COUNT=1
ENABLE_MONITORING=true
CPU_INDEXER="4"
MEMORY_INDEXER="8G"
CPU_SEARCH_HEAD="2"
MEMORY_SEARCH_HEAD="4G"
</details>

<details>
<summary><strong>Large (large-production.conf)</strong></summary>

Bash

# config-templates/large-production.conf
INDEXER_COUNT=5
SEARCH_HEAD_COUNT=2
ENABLE_MONITORING=true
CPU_INDEXER="8"
MEMORY_INDEXER="16G"
CPU_SEARCH_HEAD="4"
MEMORY_SEARCH_HEAD="8G"
</details>

📋 Manual Deployment (Advanced)
For more granular control, you can run each script individually.

1. Prerequisites
OS: RHEL/CentOS/Rocky/Fedora, Debian/Ubuntu, macOS

Tools: git, bash ≥ 4.0, sudo

2. Clone Repo
Bash

git clone https://github.com/example/Easy_Splunk.git
cd Easy_Splunk
3. Install Container Runtime
Bash

./install-prerequisites.sh
4. Configure SELinux (RHEL-based)
Bash

sudo ./generate-selinux-helpers.sh
5. Deploy Manually
Bash

# Generate credentials
yes | ./generate-credentials.sh

# Select config
cp config-templates/small-production.conf config/active.conf

# Run orchestrator
./orchestrator.sh --with-monitoring

# Check health
./health_check.sh

# Create index
./generate-splunk-configs.sh --index-name manual_index
🐛 Troubleshooting
Docker Permission Denied
Bash

sudo usermod -aG docker $USER
(You must log out and log back in for this to take effect.)

SELinux Volume Errors
Bash

sudo ./generate-selinux-helpers.sh
Check Service Health
Bash

./health_check.sh
docker compose logs <service_name>
📌 Notes for RHEL 8 ARM
Works if container images exist for linux/arm64.

Podman is recommended; ensure podman-compose supports ARM.

You may need to rebuild Splunk images if official ARM builds aren't available.