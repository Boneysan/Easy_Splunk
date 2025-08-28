# Changelog

All notable changes to Easy_Splunk will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Repository Housekeeping**: Complete reorganization with new directory structure
- **Unified CLI**: `bin/easy-splunk` as main entry point for all operations
- **Air-gapped CLI**: `bin/easy-splunk-airgap` for bundle creation
- **Backup CLI**: `bin/easy-splunk-backup` for backup/restore operations
- **Quick Start Guide**: Comprehensive 5-minute deployment guide
- **Docker vs Podman Guide**: Decision matrix for runtime selection
- **Enhanced Error Handling Guide**: Quick fixes for common issues
- **GitHub Actions CI**: Automated testing with shellcheck and compose validation
- **Smoke Tests**: Basic functionality validation for core features
- **Bundle Hardening**: Manifest-based integrity verification for air-gapped deployments

### Changed
- **Directory Structure**: Reorganized into `/bin`, `/lib`, `/scripts`, `/docs` layout
- **Deploy Scripts**: Consolidated multiple deploy variants into single authoritative `deploy.sh`
- **Developer Scripts**: Moved alternative implementations to `scripts/dev/` with documentation
- **Documentation**: Enhanced with user-focused guides and decision trees

### Fixed
- **IFS Variable**: Fixed `IFS=$nt` typo across 100+ shell scripts
- **Python 3.6 Compatibility**: Automatic Docker preference on RHEL 8
- **Podman-Compose Issues**: Enhanced detection and installation guidance
- **Error Messages**: Context-aware troubleshooting with actionable steps

## [1.0.0] - 2025-01-15

### Added
- Initial release of Easy_Splunk
- Docker and Podman support
- Splunk cluster orchestration
- Air-gapped deployment capability
- Monitoring stack (Prometheus + Grafana)
- Automated credential generation
- Comprehensive error handling

### Features
- Multi-node Splunk cluster deployment
- Runtime auto-detection (Docker/Podman)
- TLS certificate generation
- Health monitoring and checks
- Backup and restore functionality
- SELinux support
- RHEL/Fedora/CentOS/Ubuntu compatibility

---

## Version History

### Pre-1.0.0 (Development Phase)

#### Phase 1: Core Infrastructure
- Basic Docker/Podman runtime detection
- Simple compose file generation
- Initial credential management

#### Phase 2: Enhanced Features
- Multi-node cluster support
- Monitoring stack integration
- Advanced error handling
- SELinux compatibility

#### Phase 3: Production Readiness
- Air-gapped deployment support
- Comprehensive testing framework
- Documentation and user guides
- CI/CD pipeline implementation

---

## Release Process

### Version Numbering
We use [Semantic Versioning](https://semver.org/):
- **MAJOR**: Breaking changes
- **MINOR**: New features (backward compatible)
- **PATCH**: Bug fixes (backward compatible)

### Release Checklist
- [ ] Update version numbers in all relevant files
- [ ] Update CHANGELOG.md with release notes
- [ ] Run full test suite
- [ ] Create and push git tag
- [ ] Update documentation if needed
- [ ] Announce release

### Tagging Releases
```bash
# Create and push version tag
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0

# Create GitHub release with changelog
# (Use GitHub web interface or gh CLI)
```

---

## Contributing to Changelog

When contributing changes:

1. **Add entries** to the `[Unreleased]` section
2. **Categorize** changes as: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`
3. **Keep descriptions** concise but informative
4. **Reference issues/PRs** when applicable

### Example Entry
```markdown
### Added
- New feature description ([issue #123](https://github.com/user/repo/issues/123))

### Fixed
- Bug fix description ([PR #456](https://github.com/user/repo/pull/456))
```

---

## Air-gapped Users

For air-gapped environments, download release assets and verify checksums:

```bash
# Download and verify release
wget https://github.com/Boneysan/Easy_Splunk/releases/download/v1.0.0/easy-splunk-v1.0.0.tar.gz
wget https://github.com/Boneysan/Easy_Splunk/releases/download/v1.0.0/easy-splunk-v1.0.0.tar.gz.sha256

# Verify checksum
sha256sum -c easy-splunk-v1.0.0.tar.gz.sha256

# Extract and use
tar -xzf easy-splunk-v1.0.0.tar.gz
cd easy-splunk-v1.0.0
```

---

*For the latest unreleased changes, see the commit history or development branch.*
