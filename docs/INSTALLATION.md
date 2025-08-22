This document provides a detailed, step-by-step guide for new users. It covers the installation process from start to finish, offering both a simple automated path and manual platform-specific instructions, and concludes with a helpful troubleshooting guide for common issues.

-----

# Installation Guide

Welcome\! This guide will walk you through the complete process of setting up the App Cluster Orchestrator on your system. We'll cover installing prerequisites, configuring your environment, and running the application for the first time.

-----

## 📋 Prerequisites

Before you begin, please ensure your system has the following:

  * **A supported Operating System:**
      * RHEL/CentOS/Rocky/Fedora
      * Debian/Ubuntu
      * macOS
  * **`git`:** For cloning the repository.
  * **`bash`:** Version 4.0 or newer.
  * **`sudo` / Administrator privileges:** Required for installing packages and configuring the system.
  * **An internet connection:** Required for the initial download of dependencies.

-----

## Step 1: Clone the Repository

First, clone this repository to your local machine and navigate into the project directory.

```bash
git clone https://github.com/example/app-cluster-orchestrator.git
cd app-cluster-orchestrator
```

All subsequent commands should be run from the root of this `app-cluster-orchestrator` directory.

-----

## Step 2: Install a Container Runtime

This project runs on a container platform. You can use either **Docker** or **Podman**. We provide a script to automate the installation, but you can also follow the manual instructions for your specific platform.

### The Easy Way (Recommended)

Our `install-prerequisites.sh` script will detect your operating system and install the recommended container runtime and all its dependencies.

```bash
# From the project root directory:
./install-prerequisites.sh
```

The script will prompt you for confirmation before making any changes to your system.

### Manual Installation Instructions

If you prefer to install the tools manually, follow the guide for your operating system below.

#### For RHEL / CentOS / Fedora

We recommend **Podman** on RHEL-based systems as it is natively supported.

```bash
# Install Podman, Podman-Compose, and the Docker compatibility layer
sudo dnf install -y podman podman-compose podman-docker

# Enable the Podman socket so it can mimic the Docker daemon API
sudo systemctl enable --now podman.socket
```

#### For Debian / Ubuntu

**Docker** is the most common choice for Debian-based systems.

```bash
# Update package lists and install Docker
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose

# IMPORTANT: Add your user to the 'docker' group to run docker without sudo
sudo usermod -aG docker $USER

# You MUST log out and log back in for this group change to take effect.
```

#### For macOS

**Docker Desktop** is the standard for macOS. The easiest way to install it is with [Homebrew](https://brew.sh/).

```bash
# Install Docker Desktop using Homebrew
brew install --cask docker

# After installation, you MUST start the Docker Desktop application manually
# from your /Applications folder.
```

-----

## Step 3: Configure the System (RHEL-based Systems Only)

On systems like RHEL, CentOS, or Fedora, **SELinux** and `firewalld` require specific configuration to allow containers to run correctly, especially when accessing host directories (volumes).

We provide a helper script to automate this.

```bash
# This command must be run with sudo privileges
sudo ./generate-selinux-helpers.sh
```

This step is **not required** for Debian, Ubuntu, or macOS.

-----

## Step 4: Generate Credentials and Deploy

With the prerequisites installed, you can now deploy the application.

```bash
# 1. Generate security credentials (passwords, TLS certs)
#    Pipe 'yes' to auto-confirm the prompt for a quick setup.
yes | ./generate-credentials.sh

# 2. Run the main orchestrator script to deploy the cluster
./orchestrator.sh

# To include the monitoring stack (Prometheus & Grafana):
# ./orchestrator.sh --with-monitoring
```

-----

## Step 5: Verify the Installation

After the `orchestrator.sh` script completes, run the health check to ensure all services started correctly.

```bash
./health_check.sh
```

If all checks pass, you'll see a success message. Your cluster is now running\! You can access the main application at **http://localhost:8080**.

-----

## 🐛 Troubleshooting

Here are solutions to some common installation issues.

### "Permission denied" when running `docker` commands

  * **Problem:** You see an error like `Got permission denied while trying to connect to the Docker daemon socket`.
  * **Solution:** This means your user account is not in the `docker` group. Run `sudo usermod -aG docker $USER` and then **you must log out and log back in** for the change to apply.

### Containers fail with "Permission Denied" on RHEL/CentOS

  * **Problem:** Containers start but immediately exit, and logs show "Permission denied" errors when trying to write to a volume.
  * **Solution:** This is almost always an **SELinux** issue. Ensure you have run the platform helper script: `sudo ./generate-selinux-helpers.sh`. This applies the correct `container_file_t` label to the project directories so Podman can access them.

### `docker-compose` or `docker compose` command not found

  * **Problem:** The orchestrator script fails because it cannot find the compose command.
  * **Solution:** Make sure you have `docker-compose` (for Docker) or `podman-compose` (for Podman) installed and available in your system's `PATH`. The `install-prerequisites.sh` script should handle this automatically.

### `curl: (7) Failed to connect to localhost port 8080`

  * **Problem:** The deployment seems to finish, but the application is not accessible.
  * **Solution:** The containers may have failed to start correctly. Run `./health_check.sh` to see the status of all services. If any services are `unhealthy` or `restarting`, check their logs for specific errors using `docker compose logs <service_name>`.