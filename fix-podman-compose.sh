#!/bin/bash
# ==============================================================================
# fix-podman-compose.sh
# Specific fix for podman-compose issues on RHEL 8 and similar systems
# Implements targeted troubleshooting steps for current podman-compose problems
# ==============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source enhanced error handling
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Cannot load enhanced error handling from lib/error-handling.sh" >&2
    exit 1
}

# Initialize error handling
init_error_handling

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

log_step() {
    echo -e "${BLUE}[STEP]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Function to diagnose current state comprehensively
diagnose_current_state() {
    log_step "🔍 Comprehensive system diagnostics..."
    
    echo "=== DIAGNOSTIC INFORMATION ===" | tee -a "${LOG_FILE}"
    
    # Check Python version
    if command -v python3 >/dev/null 2>&1; then
        local python_version
        python_version=$(python3 --version 2>&1)
        log_step "Python version: $python_version"
        echo "$python_version" >> "${LOG_FILE}"
    else
        log_error "Python3 not found"
    fi
    
    # Check podman version
    if command -v podman >/dev/null 2>&1; then
        local podman_version
        podman_version=$(podman --version 2>&1)
        log_step "Podman version: $podman_version"
        echo "$podman_version" >> "${LOG_FILE}"
    else
        log_error "Podman not found"
        return 1
    fi
    
    # Check pip packages
    log_step "Checking pip packages..."
    if command -v pip3 >/dev/null 2>&1; then
        pip3 list | grep -E "(podman|compose|docker)" 2>&1 | tee -a "${LOG_FILE}" || true
    fi
    
    # Test basic podman functionality
    log_step "Testing basic podman functionality..."
    if timeout 10s podman info >/dev/null 2>&1; then
        log_success "✅ Basic podman functionality works"
    else
        log_error "❌ Basic podman functionality failed"
        enhanced_runtime_error "podman" "basic functionality test failed"
        return 1
    fi
    
    return 0
}

# Enhanced fix for podman-compose installation with multiple versions
fix_podman_compose_installation() {
    log_step "🔧 Enhanced podman-compose installation fix..."
    
    # Remove existing problematic installation
    log_step "Removing existing podman-compose..."
    pip3 uninstall -y podman-compose 2>&1 | tee -a "${LOG_FILE}" || true
    
    # Install required dependencies first
    log_step "Installing Python dependencies..."
    if ! pip3 install --upgrade pip 2>&1 | tee -a "${LOG_FILE}"; then
        enhanced_installation_error "pip" "pip3" "pip upgrade failed"
        return 1
    fi
    
    pip3 install pyyaml python-dotenv 2>&1 | tee -a "${LOG_FILE}" || log_warning "Some dependencies may have failed"
    
    # Try different podman-compose versions (RHEL 8 compatibility)
    local versions=("1.0.6" "1.0.3" "0.1.5")
    
    for version in "${versions[@]}"; do
        log_step "Trying podman-compose version ${version}..."
        
        if pip3 install "podman-compose==${version}" 2>&1 | tee -a "${LOG_FILE}"; then
            log_success "Successfully installed podman-compose ${version}"
            
            # Test the installation
            if test_compose_functionality "podman-compose"; then
                log_success "✅ podman-compose ${version} is working!"
                return 0
            else
                log_warning "podman-compose ${version} installed but not working properly"
                pip3 uninstall -y podman-compose 2>&1 | tee -a "${LOG_FILE}" || true
            fi
        else
            log_warning "Failed to install podman-compose ${version}"
            enhanced_installation_error "podman-compose" "pip3" "version ${version} installation failed"
        fi
    done
    
    log_error "All podman-compose versions failed"
    return 1
}

# Enhanced SELinux configuration
configure_selinux_for_containers() {
    log_step "🔒 Configuring SELinux for containers..."
    
    if ! command -v getenforce >/dev/null 2>&1; then
        log_step "SELinux tools not available"
        return 0
    fi
    
    local selinux_status
    selinux_status=$(getenforce 2>/dev/null || echo "Unknown")
    log_step "SELinux status: $selinux_status"
    
    if [[ "$selinux_status" == "Enforcing" ]]; then
        log_step "Configuring SELinux container policies..."
        
        # Set container-related SELinux booleans
        local policies=(
            "container_manage_cgroup"
            "container_use_cephfs"
            "virt_use_fusefs"
            "virt_sandbox_use_audit"
        )
        
        for policy in "${policies[@]}"; do
            if getsebool "$policy" 2>/dev/null | grep -q "off"; then
                log_step "Enabling SELinux policy: $policy"
                if ! sudo setsebool -P "$policy" on 2>&1 | tee -a "${LOG_FILE}"; then
                    log_warning "Could not enable $policy"
                fi
            else
                log_success "$policy already enabled"
            fi
        done
        
        # Install container SELinux policies if available
        if command -v dnf >/dev/null 2>&1; then
            log_step "Installing container-selinux packages..."
            sudo dnf install -y container-selinux 2>&1 | tee -a "${LOG_FILE}" || log_warning "Could not install container-selinux"
        elif command -v yum >/dev/null 2>&1; then
            log_step "Installing container-selinux packages..."
            sudo yum install -y container-selinux 2>&1 | tee -a "${LOG_FILE}" || log_warning "Could not install container-selinux"
        fi
        
        log_success "SELinux configured for containers"
    else
        log_step "SELinux not enforcing, skipping container policy setup"
    fi
}

# Create native compose alternative with enhanced integration
setup_native_compose_alternative() {
    log_step "🔄 Setting up native podman compose alternative..."
    
    # Check if native compose is available
    if ! podman compose version >/dev/null 2>&1; then
        log_warning "Native podman compose not available"
        return 1
    fi
    
    log_success "✅ Native podman compose is available"
    
    # Test native compose functionality
    if test_compose_functionality "podman compose"; then
        log_success "✅ Native podman compose functionality verified"
        
        # Create wrapper script for compatibility
        local wrapper_script="/usr/local/bin/podman-compose-native"
        log_step "Creating native compose wrapper at $wrapper_script..."
        
        sudo tee "$wrapper_script" > /dev/null << 'EOF'
#!/bin/bash
# Native podman compose wrapper for Easy_Splunk compatibility
# This script provides podman-compose compatibility using native podman compose
exec podman compose "$@"
EOF
        
        sudo chmod +x "$wrapper_script"
        
        log_success "✅ Native compose wrapper created"
        log_step "You can modify Easy_Splunk to use 'podman compose' or the wrapper"
        return 0
    else
        log_error "Native podman compose available but not functional"
        enhanced_compose_error "podman compose" "native compose functionality test failed"
        return 1
    fi
}

# Test if compose functionality works
test_compose_functionality() {
    local compose_cmd="$1"
    
    log_step "Testing $compose_cmd functionality..."
    
    # Create a minimal test directory
    local test_dir="/tmp/easy_splunk_compose_test_$$"
    mkdir -p "$test_dir"
    
    # Create a minimal test compose file
    cat > "$test_dir/docker-compose.yml" << 'EOF'
version: '3.8'
services:
  test:
    image: alpine:latest
    command: echo "Compose test successful"
EOF
    
    # Change to test directory
    local original_dir
    original_dir=$(pwd)
    cd "$test_dir" || {
        log_error "Failed to change to test directory"
        return 1
    }
    
    # Test compose validation
    local test_result=0
    if $compose_cmd config --quiet >/dev/null 2>&1; then
        log_success "$compose_cmd config validation passed"
    else
        log_warning "$compose_cmd config validation failed"
        test_result=1
    fi
    
    # Clean up
    cd "$original_dir"
    rm -rf "$test_dir"
    
    return $test_result
}

# Create comprehensive diagnostics and guide
create_enhanced_workaround_guide() {
    log_step "📝 Creating comprehensive workaround guide..."
    
    local guide_file="${SCRIPT_DIR}/PODMAN_COMPOSE_WORKAROUND.md"
    
    cat > "$guide_file" << 'EOF'
# Easy Splunk Podman-Compose Workaround Guide

## Issue Description
podman-compose is not working properly on your system. This guide provides multiple solution paths.

## Automated Solutions Available

### 🔧 Run the Automated Fix
```bash
./fix-podman-compose.sh
```

### 🩺 Run System Health Check
```bash
./health_check.sh
```

## Manual Solution Options

### Option 1: Use Native Podman Compose (Recommended)
```bash
# Check if available
podman compose version

# If available, modify Easy Splunk scripts:
# 1. Edit orchestrator.sh
# 2. Replace 'podman-compose' with 'podman compose'
# 3. Test with: ./deploy.sh small --index-name test
```

### Option 2: Docker Alternative
```bash
# Install Docker (RHEL 8)
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
sudo dnf install docker-ce docker-ce-cli containerd.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
# Log out and back in, then:
./install-prerequisites.sh --runtime docker
```

### Option 3: Upgrade Podman
```bash
# On RHEL 8, try newer Podman from container-tools module
sudo dnf module install container-tools:rhel8/common
sudo dnf update podman
```

### Option 4: Use Different Distribution
- Ubuntu 20.04+ or Debian 11+ (better podman-compose support)
- Fedora 35+ (latest container tools)
- Rocky Linux 9+ or AlmaLinux 9+

## Troubleshooting Commands

### Diagnostic Commands
```bash
# Check versions
python3 --version
podman --version
pip3 list | grep podman

# Test basic functionality
podman info
podman run hello-world

# Check SELinux
getenforce
sudo ausearch -m AVC -ts recent
```

### Reset and Retry
```bash
# Reset podman state
podman system reset --force

# Reinstall podman-compose
pip3 uninstall -y podman-compose
pip3 install podman-compose==1.0.6

# Test again
podman-compose --version
```

## Getting Help

If none of these solutions work:

1. **Check the Enhanced Error Messages** - They provide specific troubleshooting steps
2. **Review the Log Files** - Look for detailed error information
3. **Try the Health Check** - Run `./health_check.sh` for comprehensive diagnostics
4. **Open an Issue** - Include your system info and log files

## System Information Template

When reporting issues, include:

```bash
# System Info
cat /etc/os-release
python3 --version
podman --version
getenforce

# Container Tools
dnf list installed | grep container
pip3 list | grep -E "(podman|compose|docker)"

# SELinux Status
sudo sesearch -A -s container_t -t admin_home_t
sudo ausearch -m AVC -ts recent | tail -20
```
EOF

    log_success "📝 Comprehensive workaround guide created at: $guide_file"
    echo "📖 View the guide: cat $guide_file"
}

# Function to check and fix SELinux settings
check_and_fix_selinux() {
    log_step "Checking SELinux status and container settings..."
    
    # Check if SELinux is enabled
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_status
        selinux_status=$(getenforce 2>/dev/null || echo "Unknown")
        log_step "SELinux status: $selinux_status"
        
        if [[ "$selinux_status" == "Enforcing" ]]; then
            log_step "SELinux is enforcing, checking container policies..."
            
            # Check current container_manage_cgroup setting
            if getsebool container_manage_cgroup 2>/dev/null | grep -q "off"; then
                log_warning "container_manage_cgroup is off, this may cause podman-compose issues"
                log_step "Attempting to enable container_manage_cgroup..."
                
                if sudo setsebool -P container_manage_cgroup on 2>/dev/null; then
                    log_success "Successfully enabled container_manage_cgroup"
                else
                    log_error "Failed to enable container_manage_cgroup"
                    enhanced_permission_error "/sys/fs/selinux" "modify SELinux policy" "$(whoami)"
                    return 1
                fi
            else
                log_success "container_manage_cgroup is already enabled"
            fi
            
            # Additional SELinux checks for containers
            log_step "Checking additional container SELinux policies..."
            local container_policies=(
                "container_use_cephfs"
                "virt_use_fusefs"
                "virt_sandbox_use_audit"
            )
            
            for policy in "${container_policies[@]}"; do
                if getsebool "$policy" 2>/dev/null | grep -q "off"; then
                    log_step "Enabling SELinux policy: $policy"
                    sudo setsebool -P "$policy" on 2>/dev/null || log_warning "Could not enable $policy"
                fi
            done
        fi
    else
        log_step "SELinux tools not available or not installed"
    fi
}

# Main fix function
main() {
    echo "🔧 Enhanced Podman-Compose Fix Script for Easy_Splunk"
    echo "====================================================="
    echo "Targeting podman-compose issues on RHEL 8 and similar systems"
    echo "Integrating with Enhanced Error Handling system"
    echo ""
    
    # Step 0: Comprehensive diagnostics
    log_step "0. Running comprehensive system diagnostics..."
    if ! diagnose_current_state; then
        log_error "System diagnostics failed - critical issues detected"
        create_enhanced_workaround_guide
        return 1
    fi
    
    # Step 1: Verify podman-compose is working
    log_step "1. Verifying podman-compose installation and version..."
    if command -v podman-compose >/dev/null 2>&1; then
        local version_output
        if version_output=$(podman-compose --version 2>&1); then
            log_success "podman-compose found: $version_output"
            
            # Test functionality immediately
            if test_compose_functionality "podman-compose"; then
                log_success "✅ podman-compose is already working correctly!"
                echo ""
                echo "🎉 No fix needed - your podman-compose is functional!"
                echo "You can proceed with: ./deploy.sh small --index-name test"
                return 0
            else
                log_warning "podman-compose found but functionality test failed"
            fi
        else
            log_error "podman-compose command exists but version check failed"
            enhanced_compose_error "podman-compose" "version check failed"
            echo "Output: $version_output"
        fi
    else
        log_error "podman-compose not found in PATH"
        enhanced_installation_error "podman-compose" "pip3" "command not found"
    fi
    
    # Step 2: Configure SELinux (often the root cause on RHEL 8)
    log_step "2. Configuring SELinux for container support..."
    configure_selinux_for_containers
    
    # Step 3: Enhanced podman-compose installation fix
    log_step "3. Attempting enhanced podman-compose installation fix..."
    if fix_podman_compose_installation; then
        log_success "🎉 Enhanced podman-compose fix successful!"
        
        # Final verification
        if test_compose_functionality "podman-compose"; then
            log_success "✅ Final verification passed - podman-compose is working!"
            echo ""
            echo "� Success! You can now run Easy_Splunk deployment:"
            echo "   ./deploy.sh small --index-name test"
            echo "   ./health_check.sh"
            return 0
        else
            log_warning "Installation succeeded but functionality test still fails"
        fi
    else
        log_warning "Enhanced podman-compose installation fix failed"
    fi
    
    # Step 4: Try native podman compose as alternative
    log_step "4. Setting up native 'podman compose' alternative..."
    if setup_native_compose_alternative; then
        log_success "✅ Native compose alternative configured successfully!"
        echo ""
        echo "🔄 Alternative Solution Ready:"
        echo "   • Native 'podman compose' is working"
        echo "   • Wrapper script created for compatibility"
        echo "   • Modify Easy_Splunk to use 'podman compose'"
        echo ""
        echo "Next steps:"
        echo "1. Edit orchestrator.sh to use 'podman compose' instead of 'podman-compose'"
        echo "2. Test with: ./deploy.sh small --index-name test"
        return 0
    else
        log_warning "Native compose alternative setup failed"
    fi
    
    # Step 5: Create comprehensive workaround guide
    log_step "5. Creating comprehensive troubleshooting guide..."
    create_enhanced_workaround_guide
    
    echo ""
    echo "❌ AUTOMATED FIX UNSUCCESSFUL"
    echo "================================"
    echo ""
    echo "📋 Available Resources:"
    echo "• Enhanced troubleshooting guide: ./PODMAN_COMPOSE_WORKAROUND.md"
    echo "• Detailed logs: $LOG_FILE" 
    echo "• System health check: ./health_check.sh"
    echo "• Enhanced error demos: ./test-enhanced-errors.sh"
    echo ""
    echo "� Alternative Solutions:"
    echo "1. Use Docker instead: ./install-prerequisites.sh --runtime docker"
    echo "2. Try a different OS (Ubuntu 20.04+, Fedora 35+)"
    echo "3. Use podman with manual container management"
    echo "4. Contact support with the log file above"
    echo ""
    
    # Show enhanced error for final guidance
    enhanced_compose_error "podman-compose" "comprehensive fix attempt failed"
    
    return 1
}

# Help function
show_help() {
    cat << EOF
Usage: $0 [options]

Specific fix script for podman-compose issues on RHEL 8 and similar systems.

This script implements targeted troubleshooting steps:
1. Verify podman-compose installation and version
2. Test compose functionality with a simple compose file
3. Reinstall podman-compose with specific version if needed
4. Test native 'podman compose' as alternative
5. Check and fix SELinux container policies
6. Run comprehensive diagnostics

Options:
  --help, -h     Show this help message
  --verbose, -v  Enable verbose output
  --debug        Enable debug mode

Examples:
  $0                    # Run complete fix procedure
  $0 --verbose          # Run with detailed output
  $0 --debug           # Run with debug information

The script uses enhanced error handling to provide detailed troubleshooting
guidance for any issues encountered.

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            show_help
            exit 0
            ;;
        --verbose|-v)
            set -x
            ;;
        --debug)
            DEBUG=true
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
    shift
done

# Run main function
main "$@"
