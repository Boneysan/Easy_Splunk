# App Cluster Orchestrator

A comprehensive, shell-based toolkit for deploying, managing, and securing a containerized application stack with Docker or Podman.

This project provides a suite of robust, automated scripts to handle everything from initial setup and configuration to ongoing operations like monitoring, backups, and security management. It's designed to be flexible, reliable, and easy to use for both development and production environments.

-----

## ⭐ Features

  * 🚀 **Automated Deployment:** A single `orchestrator.sh` script to configure and launch the entire application stack.
  * 🐳 **Flexible Runtimes:** Out-of-the-box support for both **Docker** and **Podman**, with automatic detection and configuration.
  * 🔒 **Built-in Security:** Automated generation of credentials and self-signed TLS certificates to secure your deployment from the start.
  * 📊 **Integrated Monitoring:** One-flag setup for a complete Prometheus & Grafana monitoring stack with pre-configured dashboards.
  * ✈️ **Air-Gapped Support:** Tools to create self-contained, offline deployment bundles with SHA256 integrity verification.
  * 🛡️ **RHEL/Enterprise Ready:** Includes helper scripts to automatically configure **SELinux** and **firewalld** for seamless operation on RHEL, CentOS, and Fedora.
  * ❤️ **Robust Health Checks:** Go beyond a simple `up` command with an integrated `health_check.sh` script that verifies container status, health probes, and resource usage.
  * 📦 **Backup & Restore:** Simple, secure, and GPG-encrypted backup and restore scripts for disaster recovery planning.

-----

## 🚀 Quick Start Guide

Follow these steps to get a full deployment of the application stack running in minutes.

### Step 1: Prerequisites

First, clone the repository and ensure you have a container runtime installed. This project includes a helper script to install Docker or Podman if you don't have one.

```bash
# Clone the repository
git clone https://github.com/example/app-cluster-orchestrator.git
cd app-cluster-orchestrator

# If you don't have Docker or Podman installed, run the prerequisite installer:
# This script will guide you through installing the necessary tools for your OS.
./install-prerequisites.sh
```

### Step 2: Generate Credentials

The cluster requires credentials (passwords, API keys) and TLS certificates to run securely. Run the generator script to create them.

```bash
# This will create all necessary secrets and certs in the ./config directory.
# Pipe 'yes' to auto-confirm the prompts for a fast setup.
yes | ./generate-credentials.sh
```

### Step 3: Deploy the Cluster

Run the main orchestrator script to generate the `docker-compose.yml` file and start all the services.

```bash
# This command deploys the standard application stack.
./orchestrator.sh

# To deploy with the monitoring stack (Prometheus & Grafana) enabled:
./orchestrator.sh --with-monitoring
```

### Step 4: Verify the Deployment

After the orchestrator completes, run the health check script to confirm that all services started correctly and are healthy.

```bash
./health_check.sh
```

You should see a success message indicating that all services are running and healthy.

### Step 5: Access the Application

Your cluster is now running\!

  * **Main Application:** [http://localhost:8080](https://www.google.com/search?q=http://localhost:8080)
  * **Grafana Dashboards:** [http://localhost:3000](https://www.google.com/search?q=http://localhost:3000) (if deployed with monitoring)

-----

## 🛠️ Advanced Usage

### Air-Gapped Deployment

Follow this two-stage process to deploy in an environment with no internet access.

**On an Online Machine:**

```bash
# 1. Pin all image versions to their immutable digests
./resolve-digests.sh

# 2. Create the offline bundle (e.g., app-bundle-vX.Y.Z.tar.gz)
./create-airgapped-bundle.sh
```

**On the Offline (Air-Gapped) Machine:**

```bash
# 1. Transfer the bundle and its .sha256 checksum file to the machine.
#    Then, unpack the bundle.
tar -xzf app-bundle-vX.Y.Z.tar.gz
cd app-bundle-vX.Y.Z/

# 2. Run the quickstart script. It will verify, load, and start everything.
./airgapped-quickstart.sh
```

### Backup and Restore

**To create a secure, encrypted backup:**

```bash
# The cluster can remain running during a backup.
./backup_cluster.sh --output-dir /path/to/backups --gpg-recipient "your_gpg_key_id"
```

**To restore from a backup:**

```bash
# 1. The cluster MUST be stopped before restoring data.
./stop_cluster.sh

# 2. Run the restore script. This creates a rollback backup by default.
./restore_cluster.sh \
    --backup-file /path/to/backups/backup-YYYYMMDD-HHMMSS.tar.gz.gpg \
    --rollback-gpg-recipient "your_gpg_key_id"

# 3. Restart the cluster
./start_cluster.sh
```

### RHEL, CentOS, or Fedora Setup

If you are running on a RHEL-based system with SELinux enabled, run the platform helper script once to configure your system.

```bash
# This command must be run with sudo privileges.
sudo ./generate-selinux-helpers.sh
```

-----

## 📜 Scripts Overview

| Script                           | Description                                                                          |
| -------------------------------- | ------------------------------------------------------------------------------------ |
| `orchestrator.sh`                | **Main entry point.** Deploys the entire application stack from scratch.               |
| `start_cluster.sh`               | Starts a previously configured cluster and verifies its health.                      |
| `stop_cluster.sh`                | Gracefully stops the cluster. Use `--with-volumes` for a full data cleanup.          |
| `health_check.sh`                | Runs a comprehensive diagnostic report on the running cluster.                       |
| `install-prerequisites.sh`       | A helper script to install Docker/Podman for new users.                              |
| `generate-credentials.sh`        | Creates all necessary passwords, API keys, and TLS certificates.                     |
| `create-airgapped-bundle.sh`     | Packages all images and configs into a single `.tar.gz` for offline deployment.      |
| `backup_cluster.sh`              | Creates a secure, GPG-encrypted backup of all persistent data.                       |
| `restore_cluster.sh`             | Restores the cluster state from an encrypted backup.                                 |
| `generate-selinux-helpers.sh`    | **(For RHEL)** Configures `firewalld` and `SELinux` for the application.               |

-----

## 📄 License

This project is licensed under the MIT License.