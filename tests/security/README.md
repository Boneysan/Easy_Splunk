# Security Testing Suite

This directory contains comprehensive security vulnerability scanning and testing tools for the Easy_Splunk deployment.

## Files

### `security_scan.sh`
Main security vulnerability scanner with the following capabilities:
- **Container Security Scanning**: Uses Trivy or Grype to scan Docker images for vulnerabilities
- **Credential Exposure Detection**: Scans for hardcoded passwords, API keys, and secrets
- **File Permission Verification**: Checks for overly permissive file permissions
- **Network Security Validation**: Verifies SSL/TLS configurations and secure endpoints
- **SELinux Context Checking**: Validates SELinux contexts on supported systems
- **Dependency Security**: Scans for vulnerable script patterns

### `test_security_scan.sh`
Unit tests for the security scanner functions to ensure they work correctly.

### `run_security_tests.sh`
Comprehensive test runner and demonstration tool that:
- Checks for required security tools
- Creates sample vulnerable files for testing
- Runs security scan demonstrations
- Shows security best practices
- Manages test cleanup

## Usage

### Quick Security Scan
```bash
# Full security scan
./security_scan.sh

# Scan with automatic fixes
./security_scan.sh --fix

# Only check for credential exposure
./security_scan.sh --credentials-only

# Only verify file permissions
./security_scan.sh --permissions-only
```

### Testing and Demonstration
```bash
# Run full test suite with demos
./run_security_tests.sh

# Create sample vulnerable files and run demo
./run_security_tests.sh --create-samples --demo

# Show security best practices
./run_security_tests.sh --best-practices

# Clean up test files
./run_security_tests.sh --cleanup
```

### Unit Tests
```bash
# Run unit tests for scanner functions
./test_security_scan.sh
```

## Security Scan Options

### Command Line Options
- `--fix`: Enable automatic fixing of identified issues
- `--severity LEVEL`: Set minimum severity threshold (CRITICAL|HIGH|MEDIUM|LOW)
- `--output DIR`: Set custom output directory for scan results
- `--containers-only`: Run only container vulnerability scans
- `--credentials-only`: Run only credential exposure scans
- `--permissions-only`: Run only file permission checks
- `--network-only`: Run only network security checks
- `--help`: Show help message

### Exit Codes
- `0`: Success, no critical/high issues found
- `1`: Critical or high-severity issues found
- `2`: Scan failed due to error

## Required Tools

### Essential
- `bash` (4.0+)
- `jq` - JSON processing
- `grep` - Pattern matching
- `find` - File searching
- `stat` - File information

### Container Scanning
- `docker` or `podman` - Container runtime
- `trivy` - Vulnerability scanner (recommended)
- `grype` - Alternative vulnerability scanner (optional)

### Installation Commands
```bash
# Install Trivy (Linux/macOS)
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh

# Install Grype (Linux/macOS)
curl -sSfL https://raw.githubusercontent.com/anchore/grype/main/install.sh | sh

# Install jq (Ubuntu/Debian)
sudo apt-get install jq

# Install jq (RHEL/CentOS/Fedora)
sudo yum install jq
```

## Security Scan Results

### Output Formats
- **Console Output**: Human-readable results with color coding
- **JSON Report**: Machine-readable detailed results
- **Text Report**: Formatted summary report

### Report Location
Results are saved in `./scan_results/` directory:
- `security_scan_YYYYMMDD_HHMMSS.json` - Detailed JSON report
- `security_report_YYYYMMDD_HHMMSS.txt` - Human-readable summary

## Security Best Practices

### Container Security
- Regularly scan images for vulnerabilities
- Use specific image tags instead of 'latest'
- Keep base images updated
- Run containers as non-root users

### Credential Management
- Never hardcode credentials in files
- Use environment variables or secret management systems
- Rotate credentials regularly
- Use strong, unique passwords

### File Permissions
- Restrict sensitive files (600/700 permissions)
- Avoid world-writable files
- Regular permission audits
- Proper SELinux contexts

### Network Security
- Use HTTPS/TLS for external communications
- Enable SSL for Splunk data transmission
- Configure firewalls appropriately
- Use VPNs for remote access

## Integration with CI/CD

The security scanner can be integrated into CI/CD pipelines:

```bash
# Example Jenkins/GitHub Actions step
./tests/security/security_scan.sh --severity HIGH
if [ $? -eq 1 ]; then
    echo "Security scan found critical issues - failing build"
    exit 1
fi
```

## Troubleshooting

### Common Issues
1. **Permission Denied**: Ensure scripts are executable
2. **Missing Tools**: Install required dependencies
3. **Container Runtime**: Ensure Docker/Podman is running
4. **SELinux**: May need appropriate contexts for file access

### Debug Mode
Set environment variables for debugging:
```bash
export DEBUG=true
export LOG_LEVEL=debug
./security_scan.sh
```

## Contributing

When adding new security checks:
1. Add the check function to `security_scan.sh`
2. Create corresponding unit tests in `test_security_scan.sh`
3. Update this README with new functionality
4. Test with the demonstration runner

## Security Reporting

If you discover security vulnerabilities in this toolkit:
1. Do NOT create public issues
2. Contact the maintainers privately
3. Provide detailed reproduction steps
4. Allow time for fixes before disclosure
