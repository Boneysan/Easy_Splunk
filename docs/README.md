# 📚 Documentation Index

Welcome to the Easy_Splunk documentation! This index helps you find the right guide for your needs.

## 🚀 Getting Started (Start Here!)

| Guide | Purpose | Time to Read |
|-------|---------|--------------|
| **[🚀 Quick Start Guide](../QUICK_START.md)** | Get running in 5 minutes | 2 minutes |
| **[🐳 Docker vs Podman Guide](../DOCKER_PODMAN_GUIDE.md)** | Runtime selection explained | 3 minutes |
| **[🚨 Enhanced Error Handling: Start Here](../ENHANCED_ERROR_START_HERE.md)** | Quick fixes for common issues | 2 minutes |

## 📦 Installation & Setup

| Guide | Purpose | Audience |
|-------|---------|----------|
| **[Installation Guide](INSTALLATION.md)** | Complete setup instructions | New users |
| **[Prerequisites Script](../install-prerequisites.sh)** | Automated dependency installation | All users |
| **[Generate Credentials](../generate-credentials.sh)** | TLS certificates and passwords | Administrators |

## ⚙️ Configuration & Deployment

| Guide | Purpose | Use Case |
|-------|---------|----------|
| **[Small Production Config](../config-templates/small-production.conf)** | Basic cluster setup | Development/Testing |
| **[Medium Production Config](../config-templates/medium-production.conf)** | Balanced production | Small teams |
| **[Large Production Config](../config-templates/large-production.conf)** | Enterprise scale | Large deployments |
| **[Development Config](../config-templates/development.conf)** | Single-node testing | Developers |

## 🚨 Troubleshooting & Error Handling

| Guide | Purpose | When to Use |
|-------|---------|-------------|
| **[Enhanced Error Handling Guide](../ENHANCED_ERROR_HANDLING_GUIDE.md)** | Complete troubleshooting reference | When stuck |
| **[Enhanced Error Handling](../ENHANCED_ERROR_HANDLING.md)** | Technical implementation details | Developers |
| **[Error Handling Summary](../ENHANCED_ERROR_HANDLING_SUMMARY.md)** | Executive overview | Managers |
| **[Fix Podman Compose](../fix-podman-compose.sh)** | podman-compose installation issues | RHEL 8 users |
| **[Fix Python Compatibility](../fix-python-compatibility.sh)** | Python 3.6 compatibility | RHEL 8 users |
| **[Fix Docker Permissions](../fix-docker-permissions.sh)** | Docker access issues | Permission errors |

## 🔒 Security & Compliance

| Guide | Purpose | Audience |
|-------|---------|----------|
| **[Security Validation](SECURITY_VALIDATION.md)** | Security checklist and validation | Security teams |
| **[Secrets Hygiene](../fix-secrets-hygiene.sh)** | Credential management best practices | Administrators |
| **[SELinux Helpers](../generate-selinux-helpers.sh)** | SELinux policy generation | RHEL/CentOS admins |

## 🐳 Container Runtime Specific

| Guide | Purpose | Runtime |
|-------|---------|---------|
| **[RHEL 8 Docker Preference](../rhel8-docker-preference-summary.sh)** | RHEL 8 optimizations | Docker on RHEL |
| **[Ubuntu Docker Preference](../ubuntu-docker-preference-summary.sh)** | Ubuntu optimizations | Docker on Ubuntu |
| **[Compose Fallback](../compose-fallback-updates-summary.sh)** | Alternative compose methods | All runtimes |

## 📊 Monitoring & Observability

| Guide | Purpose | Component |
|-------|---------|-----------|
| **[Start Monitoring](../monitoring/start-monitoring.sh)** | Enable monitoring stack | Prometheus + Grafana |
| **[Generate Monitoring Config](../generate-monitoring-config.sh)** | Configure monitoring | All components |
| **[Health Check Enhanced](../health_check_enhanced.sh)** | Comprehensive health validation | All services |

## 🔄 Operations & Maintenance

| Guide | Purpose | Frequency |
|-------|---------|-----------|
| **[Backup Cluster](../backup_cluster.sh)** | Create system backups | Weekly/Monthly |
| **[Restore Cluster](../restore_cluster.sh)** | Restore from backups | As needed |
| **[Air-gapped Quickstart](../airgapped-quickstart.sh)** | Offline deployment | Initial setup |

## 🧪 Testing & Validation

| Guide | Purpose | Environment |
|-------|---------|-------------|
| **[Smoke Tests](../tests/smoke/)** | Basic functionality validation | All environments |
| **[Run All Tests](../run_all_tests.sh)** | Comprehensive test suite | Development |
| **[Bundle Hardening](../bundle-hardening.sh)** | Air-gapped bundle validation | Production |

## 📋 Best Practices & Standards

| Guide | Purpose | Audience |
|-------|---------|----------|
| **[Bash Best Practices](BASH_BEST_PRACTICES_GUIDE.md)** | Shell scripting standards | Developers |
| **[Header Standardization](HEADER_STANDARDIZATION.md)** | Code formatting guidelines | Contributors |

## 🎯 Quick Reference

### Most Common Issues (Solutions)
1. **podman-compose not found** → [Fix Podman Compose](../fix-podman-compose.sh)
2. **Python 3.6 syntax error** → [Fix Python Compatibility](../fix-python-compatibility.sh)
3. **Docker permission denied** → [Fix Docker Permissions](../fix-docker-permissions.sh)
4. **Port already in use** → `sudo lsof -ti:8000 \| xargs kill -9`
5. **SELinux permission denied** → [Generate SELinux Helpers](../generate-selinux-helpers.sh)

### Most Used Scripts
- `./install-prerequisites.sh` - Setup dependencies
- `./generate-credentials.sh` - Create certificates
- `./deploy.sh` - Deploy cluster
- `./health_check.sh` - Verify deployment
- `./fix-podman-compose.sh` - Fix compose issues

## 📞 Support & Contributing

- **Issues**: [GitHub Issues](https://github.com/Boneysan/Easy_Splunk/issues)
- **Discussions**: [GitHub Discussions](https://github.com/Boneysan/Easy_Splunk/discussions)
- **Contributing**: See [CONTRIBUTING.md](../CONTRIBUTING.md) (if exists)

---

**💡 Tip**: Start with the [Quick Start Guide](../QUICK_START.md) for immediate results, then explore specific guides as needed!
