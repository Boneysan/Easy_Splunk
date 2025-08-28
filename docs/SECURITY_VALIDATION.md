# Security Validation Framework

This document describes the comprehensive security validation system implemented for the Easy Splunk deployment platform.

## Overview

The security validation framework provides two main security layers:

1. **SELinux Preflight Validation** - Ensures Docker containers work properly with SELinux enforcing mode
2. **Supply Chain Security** - Enforces image digest validation in production/air-gapped environments

## SELinux Preflight Validation

### Purpose
When SELinux is in enforcing mode and Docker is used as the container runtime, bind mounts require the `:Z` flag to properly label files for container access. Without this flag, containers get permission denied errors when accessing mounted volumes.

### Implementation
- **Library**: `lib/selinux-preflight.sh`
- **Functions**:
  - `get_selinux_status()` - Detects if SELinux is enforcing
  - `detect_container_runtime()` - Determines if Docker or Podman is in use
  - `validate_volume_mount()` - Checks if Docker bind mounts have `:Z` flags
  - `selinux_preflight_check()` - Main validation function

### Integration
The SELinux validation is automatically called during compose validation in `validate_before_deploy()`.

### Automatic Remediation
The compose generator (`lib/compose-generator.sh`) includes `add_selinux_flag_if_needed()` which automatically adds `:Z` flags to Docker bind mounts when SELinux is enforcing.

## Supply Chain Security

### Purpose
Prevents supply chain attacks by enforcing immutable image digests in production environments, blocking the use of mutable tags like `:latest` that could be compromised.

### Implementation
- **Library**: `lib/image-validator.sh`
- **Functions**:
  - `detect_deployment_mode()` - Identifies production/air-gapped environments
  - `validate_image_supply_chain()` - Validates individual images have digest format
  - `validate_compose_supply_chain()` - Validates all images in compose files
  - `validate_deployment_supply_chain()` - Comprehensive deployment validation

### Production Mode Detection
The system automatically detects production environments based on:
- Environment variables (`DEPLOYMENT_MODE`, `ENVIRONMENT`, `NODE_ENV`)
- Air-gapped indicators (`AIR_GAPPED_MODE`, file paths)
- Configuration file patterns (`production.conf`, air-gapped scripts)

Detected production modes:
- `production`, `prod`
- `air-gapped`, `airgapped`
- `secure`, `enterprise`

### Digest Enforcement Patterns
In production mode, these image patterns require digest format:
- `splunk/*` - All Splunk images
- `prom/*` - Prometheus stack images  
- `grafana/*` - Grafana images
- `*:latest` - Any image tagged as latest
- `*:main` - Any image tagged as main

### Image Resolution
The `resolve-digests.sh` script:
1. Pulls images defined in `versions.env`
2. Extracts immutable sha256 digests
3. Updates `versions.env` with digest-based image references
4. Validates supply chain compliance after resolution

## Usage

### Manual Validation
```bash
# SELinux validation
source lib/selinux-preflight.sh
selinux_preflight_check docker-compose.yml

# Supply chain validation  
source lib/image-validator.sh
validate_compose_supply_chain docker-compose.yml

# Full validation pipeline
source lib/compose-validation.sh
validate_before_deploy docker-compose.yml
```

### Automated Validation
The validation framework is automatically integrated into:
- `deploy.sh` - Full deployment validation
- `start_cluster.sh` - Pre-start validation  
- `orchestrator.sh` - Orchestrated deployment validation

### Digest Resolution
```bash
# Generate production-ready versions.env with digests
./resolve-digests.sh

# Deploy with validated images
export DEPLOYMENT_MODE=production
./deploy.sh
```

## Configuration

### Environment Variables
- `DEPLOYMENT_MODE` - Set to `production` for strict validation
- `AIR_GAPPED_MODE` - Set to `true` for air-gapped environments
- `SKIP_SECURITY_VALIDATION` - Set to disable security checks (not recommended)

### Development vs Production
- **Development**: Uses image tags (`:10.0.0`), SELinux validation only
- **Production**: Enforces image digests (`@sha256:...`), full security validation

## Error Handling

### SELinux Issues
If SELinux validation fails, you'll see:
```
ERROR: Docker bind mount missing :Z flag for SELinux compatibility
Mount: ./data/splunk:/opt/splunk/var
Fix: ./data/splunk:/opt/splunk/var:Z
```

### Supply Chain Issues  
If supply chain validation fails in production:
```
ERROR: Production deployment requires image digests for security
Image: splunk/splunk:10.0.0 (uses mutable tag)
Fix: Use splunk/splunk@sha256:... or run resolve-digests.sh
```

## Security Benefits

1. **Container Compatibility**: Prevents SELinux permission denied errors
2. **Supply Chain Security**: Blocks mutable tag attacks in production
3. **Air-gapped Support**: Enforces digest validation for offline environments
4. **Automated Remediation**: Auto-fixes SELinux volume mount issues
5. **Defense in Depth**: Multiple validation layers for comprehensive security

## Files Modified

- `lib/selinux-preflight.sh` - SELinux validation module (new)
- `lib/image-validator.sh` - Supply chain security module (new)  
- `lib/compose-validation.sh` - Enhanced with security validation
- `lib/compose-generator.sh` - Enhanced with SELinux auto-fix
- `resolve-digests.sh` - Enhanced with supply chain validation
- `versions.env` - Updated with digest format examples

## Testing

Run the security validation test suite:
```bash
./test-security-validation.sh
```

This validates:
- SELinux status detection
- Container runtime detection  
- Volume mount validation
- Production mode detection
- Supply chain enforcement
- Full validation pipeline
