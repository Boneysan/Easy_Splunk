# Smoke Tests

This directory contains smoke tests for the Easy_Splunk project. These are lightweight, fast-running tests that validate core functionality without requiring heavy dependencies or external services.

## Available Tests

### `smoke_generate_compose.sh`
Tests the compose file generation functionality:
- ✅ Generates compose files from config templates (e.g., `small-production.conf`)
- ✅ Validates generated YAML syntax
- ✅ Checks for common lint issues (trailing whitespace, tabs)
- ✅ Ensures required services are present

### `smoke_airgapped_bundle.sh`
Tests the air-gapped bundle functionality:
- ✅ Tests digest resolution with dummy images (busybox, nginx:alpine)
- ✅ Validates bundle manifest generation
- ✅ Tests bundle verification against manifest
- ✅ Checks re-download command generation

## Running Tests

### Run All Smoke Tests
```bash
cd tests/smoke
./smoke_generate_compose.sh
./smoke_airgapped_bundle.sh
```

### Run Individual Tests
```bash
# Test compose generation
./smoke_generate_compose.sh

# Test air-gapped bundle functionality
./smoke_airgapped_bundle.sh
```

## CI Integration

These tests are automatically run in GitHub Actions as part of the CI pipeline:

- **ShellCheck**: Validates all `.sh` files for common issues
- **Compose Validation Matrix**: Runs smoke tests with both Docker and Podman
- **Template Regeneration Check**: Ensures generated templates match committed files

## Test Design Principles

- **Fast**: Tests complete in under 5 minutes
- **Isolated**: No external dependencies beyond container runtimes
- **Safe**: Uses dummy images (busybox) instead of Splunk images
- **Comprehensive**: Covers critical paths without full integration testing

## Dependencies

- Bash 4.0+
- Docker or Podman (for compose validation)
- Python 3 (for JSON validation in bundle tests)
- Core project libraries (`lib/*.sh`)

## Troubleshooting

### Common Issues

1. **Permission Denied**: Make sure scripts are executable
   ```bash
   chmod +x tests/smoke/*.sh
   ```

2. **Missing Dependencies**: Ensure required libraries are present
   ```bash
   ls lib/*.sh
   ```

3. **Container Runtime Issues**: Tests will skip validation if no runtime is available

### Debug Mode

Run with verbose output:
```bash
bash -x tests/smoke/smoke_generate_compose.sh
```
