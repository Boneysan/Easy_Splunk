# 📤 Air-Gapped Deployment Guide

Complete guide for deploying Easy_Splunk in air-gapped (offline) environments with cluster size configuration.

---

## 🎯 Overview

Air-gapped deployment allows you to run Easy_Splunk in environments without internet connectivity by pre-packaging all required components. This guide covers the complete three-step process for creating and deploying size-configured Splunk clusters in air-gapped environments.

## 📋 Prerequisites

### Connected Machine (Bundle Creation)
- Linux system with internet access
- Docker or Podman installed
- Easy_Splunk repository cloned
- At least 10GB free disk space

### Air-Gapped Machine (Deployment)
- Linux system (same architecture as connected machine)
- Docker or Podman installed (Docker recommended)
- No internet connectivity required
- Sufficient resources for chosen cluster size

## 🚀 Three-Step Process

### **Step 1: Generate Compose File with Desired Cluster Size (Connected Machine)**

First, generate a `docker-compose.yml` file configured for your specific cluster size:

```bash
# For small production cluster (1 indexer, 1 search head, ~6GB)
./deploy.sh small --dry-run --config config-templates/small-production.conf

# For medium production cluster (3 indexers, 2 search heads, ~16GB)  
./deploy.sh medium --dry-run --config config-templates/medium-production.conf

# For large production cluster (6+ indexers, 3+ search heads, ~32GB+)
./deploy.sh large --dry-run --config config-templates/large-production.conf

# Alternative unified CLI syntax
./bin/easy-splunk deploy --dry-run --config config-templates/medium-production.conf
```

**What `--dry-run` does:**
- ✅ Generates `docker-compose.yml` with specified cluster size
- ✅ Creates configuration files and templates
- ✅ Sets up proper service profiles (small, medium, large)
- ✅ Configures resource limits (CPU, memory)
- ❌ Does NOT deploy or start containers

### **Step 2: Create Air-Gapped Bundle (Connected Machine)**

Create the air-gapped bundle containing all required components:

```bash
# Resolve and pin image digests for security (recommended)
./resolve-digests.sh

# Create the complete air-gapped bundle
./create-airgapped-bundle.sh --with-secrets

# Alternative unified CLI approach
./bin/easy-splunk-airgap --resolve-digests --verify
```

**Bundle Contents:**
- 📦 Container images archive (`images.tar.gz`)
- 🐳 Your size-configured `docker-compose.yml` from Step 1
- ⚙️ Configuration files and templates
- 🔧 Scripts and libraries
- 🔐 Credentials (if `--with-secrets` used)
- 📋 Security manifests and checksums
- 📚 Documentation and guides

**Output:**
```bash
# Bundle will be created as:
splunk-cluster-airgapped-YYYYMMDD.tar.gz
splunk-cluster-airgapped-YYYYMMDD.tar.gz.sha256
```

### **Step 3: Deploy on Air-Gapped Target (Offline Machine)**

Transfer the bundle to your air-gapped system and deploy:

```bash
# Transfer bundle to air-gapped system (USB, secure file transfer, etc.)
# Extract the bundle
tar -xzf splunk-cluster-airgapped-*.tar.gz
cd splunk-cluster-airgapped-*/

# Verify bundle integrity and contents
./verify-bundle.sh

# Deploy with your pre-configured cluster size
./airgapped-quickstart.sh

# Optional: Check deployment status
./health_check.sh  # (if included in bundle)
```

## 📊 Available Cluster Sizes

| Template | Indexers | Search Heads | Memory | CPU | Use Case |
|----------|----------|--------------|--------|-----|----------|
| **small** | 1 | 1 | ~6GB | 2-4 cores | Development, small teams |
| **medium** | 3 | 2 | ~16GB | 8-12 cores | Production, moderate load |
| **large** | 6+ | 3+ | ~32GB+ | 16+ cores | High-volume production |

## 🔧 Advanced Configuration

### Custom Cluster Sizes

You can create custom configurations by copying and modifying existing templates:

```bash
# Create custom configuration
cp config-templates/medium-production.conf my-custom.conf

# Edit as needed (indexer count, memory limits, etc.)
vim my-custom.conf

# Generate compose with custom config
./deploy.sh --dry-run --config my-custom.conf

# Then proceed with bundle creation
```

### Adding Extra Images

Include additional container images in your bundle:

```bash
./create-airgapped-bundle.sh --image alpine:latest --image redis:7 --with-secrets
```

### Including Extra Files

Add custom files or directories to the bundle:

```bash
./create-airgapped-bundle.sh --include docs/ --include custom-configs/ --with-secrets
```

## 🛠️ Troubleshooting

### Common Issues and Solutions

#### Bundle Creation Fails
```bash
# Check logs for details
cat logs/create-airgapped-bundle-*.log

# Verify Docker/Podman is working
docker --version
docker info

# Check disk space
df -h .
```

#### Image Digest Resolution Fails
```bash
# Manually resolve digests
./resolve-digests.sh --verbose

# Skip digest resolution (not recommended for production)
./create-airgapped-bundle.sh --skip-digests
```

#### Bundle Verification Fails on Target
```bash
# Check bundle integrity
./verify-bundle.sh --verbose

# Re-extract bundle
tar -xzf splunk-cluster-airgapped-*.tar.gz --verbose
```

#### Deployment Fails on Air-Gapped System
```bash
# Check container runtime
docker --version  # or podman --version

# Verify images were loaded
docker images | grep splunk

# Check compose file
./airgapped-quickstart.sh --compose-file docker-compose.yml
```

### Size Template Not Applied

If your deployed cluster doesn't match the expected size:

```bash
# Verify the compose file was generated correctly
grep -A 5 -B 5 'profiles:' docker-compose.yml

# Check for expected services
docker-compose config --services

# Regenerate if needed (on connected machine)
./deploy.sh [size] --dry-run --config config-templates/[size]-production.conf
```

## 🔒 Security Considerations

### Image Digest Pinning

Always use image digest pinning for air-gapped production deployments:

```bash
# This is done automatically by resolve-digests.sh
./resolve-digests.sh
```

**Before (mutable tags):**
```yaml
image: splunk/splunk:10.0.0
```

**After (immutable digests):**
```yaml
image: splunk/splunk@sha256:abc123def456...
```

### Bundle Verification

Always verify bundle integrity on the target system:

```bash
# Mandatory verification step
./verify-bundle.sh

# This checks:
# ✅ Bundle checksums
# ✅ Manifest integrity  
# ✅ Image archive validity
# ✅ Required files present
```

## 📚 Related Documentation

- **[Main README](README.md)** - Complete toolkit overview
- **[Quick Start Guide](QUICK_START.md)** - Fast deployment guide
- **[Docker vs Podman Guide](DOCKER_PODMAN_GUIDE.md)** - Runtime selection
- **[Security Validation](docs/SECURITY_VALIDATION.md)** - Security best practices
- **[Enhanced Error Handling](ENHANCED_ERROR_START_HERE.md)** - Troubleshooting guide

## 💡 Best Practices

1. **Test First**: Always test your bundle creation and deployment process in a non-production environment
2. **Size Planning**: Choose appropriate cluster size based on expected data volume and query load
3. **Resource Planning**: Ensure target systems have sufficient resources for chosen cluster size
4. **Bundle Management**: Use version control and systematic naming for air-gapped bundles
5. **Security**: Always use digest pinning and bundle verification in production
6. **Documentation**: Document your specific air-gapped deployment process for your environment

## 🎓 Example Workflow

Complete example for medium production cluster:

```bash
# === On Connected Machine ===
git clone https://github.com/Boneysan/Easy_Splunk.git
cd Easy_Splunk

# Generate medium cluster compose file
./deploy.sh medium --dry-run --config config-templates/medium-production.conf

# Create air-gapped bundle
./resolve-digests.sh
./create-airgapped-bundle.sh --with-secrets

# Transfer splunk-cluster-airgapped-*.tar.gz to air-gapped system

# === On Air-Gapped Machine ===
tar -xzf splunk-cluster-airgapped-20250925.tar.gz
cd splunk-cluster-airgapped-20250925/

# Verify and deploy
./verify-bundle.sh
./airgapped-quickstart.sh

# Access Splunk
echo "Splunk Web: http://localhost:8000"
echo "Default credentials in: credentials/"
```

This workflow creates a complete medium-sized Splunk cluster (3 indexers, 2 search heads) ready for production use in an air-gapped environment.