# Enhanced Error Handling User Guide

## 🎯 Overview

The Easy_Splunk deployment system now includes comprehensive enhanced error handling that transforms cryptic error messages into actionable troubleshooting guidance.

## 🚀 Quick Start

### Before You Begin
Enhanced error handling is automatically enabled in all Easy_Splunk scripts. No additional setup required!

### Basic Usage
```bash
# Deploy with enhanced error handling
./deploy.sh small --index-name test

# Fix podman-compose issues automatically
./fix-podman-compose.sh

# Run comprehensive health check
./health_check.sh

# Demo enhanced error handling
./test-enhanced-errors.sh
```

## 🔧 Enhanced Error Examples

### Compose Errors
**Before**: `[ERROR] Compose command failed`  
**After**:
```bash
[ERROR] Compose verification failed - podman-compose not working
[INFO] Troubleshooting steps:
[INFO] 1. Try: podman-compose --version
[INFO] 2. Check: pip3 list | grep podman-compose  
[INFO] 3. Reinstall: pip3 install podman-compose==1.0.6
[INFO] 4. Alternative: Use native 'podman compose' if available
[INFO] 5. Verify runtime: podman --version
[INFO] 6. 🔧 Run automated fix: ./fix-podman-compose.sh
[INFO] Logs available at: /tmp/easy_splunk_20250820_152933.log
```

### Installation Errors
**Before**: `[ERROR] Installation failed`  
**After**:
```bash
[ERROR] Installation verification failed - python3-pip via package_manager
[INFO] Troubleshooting steps:
[INFO] 1. Update package lists: sudo apt update
[INFO] 2. Try different package: sudo apt install python3-pip
[INFO] 3. Check repositories: apt-cache policy python3-pip
[INFO] 4. Manual install: curl https://bootstrap.pypa.io/get-pip.py | python3
[INFO] 5. Alternative: Use distribution packages
[INFO] Logs available at: /tmp/easy_splunk_20250820_152933.log
```

### Runtime Errors
**Before**: `[ERROR] Container runtime failed`  
**After**:
```bash
[ERROR] Runtime verification failed - podman socket permission denied
[INFO] Troubleshooting steps:
[INFO] 1. Check service: systemctl --user status podman.socket
[INFO] 2. Start service: systemctl --user start podman.socket
[INFO] 3. Check permissions: ls -la /run/user/$UID/podman/
[INFO] 4. Reset state: podman system reset
[INFO] 5. Check subuid/subgid: id && cat /etc/subuid /etc/subgid
[INFO] Logs available at: /tmp/easy_splunk_20250820_152933.log
```

## 🛠️ Automated Fix Tools

### Podman-Compose Fix Script
**Purpose**: Automatically diagnose and fix podman-compose issues

**Usage**:
```bash
./fix-podman-compose.sh           # Run complete fix process
./fix-podman-compose.sh --verbose # Detailed output
./fix-podman-compose.sh --help    # Show all options
```

**What it does**:
1. **Comprehensive diagnostics** - System analysis and version checking
2. **SELinux configuration** - Container policy setup for RHEL/CentOS
3. **Multi-version installation** - Attempts 1.0.6, 1.0.7, and latest versions
4. **Native compose setup** - Configures 'podman compose' as alternative
5. **Documentation generation** - Creates troubleshooting guides

## 📊 Error Categories

### 1. Compose Errors (`enhanced_compose_error`)
- podman-compose version issues
- Functionality test failures
- Configuration validation problems

### 2. Installation Errors (`enhanced_installation_error`)
- Package installation failures
- Dependency resolution issues
- Permission problems during install

### 3. Runtime Errors (`enhanced_runtime_error`)
- Container runtime startup issues
- Socket permission problems
- Service configuration errors

### 4. Network Errors (`enhanced_network_error`)
- Container network connectivity
- Port binding conflicts
- DNS resolution issues

### 5. Permission Errors (`enhanced_permission_error`)
- File/directory access issues
- User/group permission problems
- SELinux context errors

## 🔍 Troubleshooting Workflow

### Step 1: Read the Enhanced Error Message
Enhanced errors provide specific troubleshooting steps numbered 1-6, follow them in order.

### Step 2: Check the Log File
Every error includes a log file location: `/tmp/easy_splunk_YYYYMMDD_HHMMSS.log`

### Step 3: Use Automated Fixes
Many errors include references to automated fix scripts:
```bash
./fix-podman-compose.sh    # For compose issues
./health_check.sh          # For system health
```

### Step 4: Try Alternative Solutions
Enhanced errors often provide multiple solution paths:
- Primary fix attempt
- Alternative approaches
- Fallback options

### Step 5: Consult Documentation
Auto-generated guides provide comprehensive troubleshooting:
- `PODMAN_COMPOSE_WORKAROUND.md` - Specific podman-compose solutions
- `ENHANCED_ERROR_HANDLING_SUMMARY.md` - Implementation details

## 🎛️ Configuration Options

### Enable Debug Mode
```bash
export DEBUG=true
./deploy.sh small --index-name test
```

### Custom Log Location
```bash
export LOG_FILE="/custom/path/deployment.log"
./deploy.sh small --index-name test
```

### Disable Enhanced Errors (Not Recommended)
```bash
export ENHANCED_ERRORS=false
./deploy.sh small --index-name test
```

## 📋 Common Scenarios

### Scenario 1: First-Time Setup on RHEL 8
```bash
# Install prerequisites with enhanced error handling
./install-prerequisites.sh

# If errors occur, they'll include specific RHEL 8 guidance
# Example: SELinux configuration, container-tools module setup
```

### Scenario 2: podman-compose Not Working
```bash
# Run automated fix
./fix-podman-compose.sh

# If that fails, check the workaround guide
cat PODMAN_COMPOSE_WORKAROUND.md
```

### Scenario 3: Deployment Failures
```bash
# Deploy with enhanced diagnostics
./deploy.sh small --index-name test

# Enhanced errors will guide you through:
# - Container runtime issues
# - Network configuration problems  
# - Permission conflicts
# - Resource constraints
```

## 🔧 Developer Integration

### Adding Enhanced Errors to New Scripts
```bash
#!/bin/bash

# Source the enhanced error handling library
source lib/error-handling.sh

# Use enhanced errors in your code
if ! some_command; then
    enhanced_installation_error "package-name" "installation-method" "specific context"
    exit 1
fi

# Available functions:
# enhanced_compose_error "compose-cmd" "error-context"
# enhanced_installation_error "package" "method" "context"  
# enhanced_runtime_error "runtime" "error-context"
# enhanced_network_error "network-context"
# enhanced_permission_error "path" "permission-context"
```

## 📈 Success Metrics

Enhanced error handling has transformed the user experience:

- **Before**: Generic error messages with no guidance
- **After**: Specific 5-step troubleshooting for each error
- **Automated Fixes**: One-command resolution for common issues
- **Multiple Solutions**: Primary and fallback approaches
- **Self-Service**: Users can resolve most issues independently

## 🎉 Getting Help

### If Enhanced Errors Don't Resolve Your Issue

1. **Check the log file** mentioned in the error output
2. **Run the health check**: `./health_check.sh`
3. **Review auto-generated guides**: `cat PODMAN_COMPOSE_WORKAROUND.md`
4. **Try alternative approaches** mentioned in the error output
5. **Contact support** with the enhanced error output and log file

### Additional Resources
- **System Health**: `./health_check.sh`
- **Error Demos**: `./test-enhanced-errors.sh`  
- **Fix Scripts**: `./fix-podman-compose.sh`
- **Validation**: `./final-validation-test.sh`

The enhanced error handling system provides comprehensive guidance for resolving deployment issues quickly and effectively!
