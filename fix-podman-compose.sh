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

# Function to test compose with a simple file
test_compose_functionality() {
    local compose_cmd="$1"
    local test_file="${SCRIPT_DIR}/test-compose.yml"
    
    log_step "Creating test compose file..."
    cat > "${test_file}" << 'EOF'
version: '3.8'
services:
  test:
    image: docker.io/library/hello-world:latest
    command: echo "Hello from compose test"
EOF

    log_step "Testing compose config validation with: $compose_cmd"
    if timeout 30s $compose_cmd -f "${test_file}" config >/dev/null 2>&1; then
        log_success "Compose config validation successful"
        rm -f "${test_file}"
        return 0
    else
        log_error "Compose config validation failed"
        rm -f "${test_file}"
        return 1
    fi
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
    echo "🔧 Podman-Compose Specific Fix Script"
    echo "====================================="
    echo "Targeting common podman-compose issues on RHEL 8 and similar systems"
    echo ""
    
    # Step 1: Verify podman-compose is working
    log_step "1. Verifying podman-compose installation and version..."
    if command -v podman-compose >/dev/null 2>&1; then
        local version_output
        if version_output=$(podman-compose --version 2>&1); then
            log_success "podman-compose found: $version_output"
        else
            log_error "podman-compose command exists but version check failed"
            enhanced_compose_error "podman-compose" "version check failed"
            echo ""
            echo "Output: $version_output"
        fi
    else
        log_error "podman-compose not found in PATH"
        enhanced_installation_error "podman-compose" "pip3" "command not found"
        echo ""
        log_step "Attempting to install podman-compose..."
        
        if command -v pip3 >/dev/null 2>&1; then
            pip3 install --user podman-compose==1.0.6 || {
                enhanced_installation_error "podman-compose" "pip3" "installation failed"
                return 1
            }
            log_success "podman-compose installed successfully"
        else
            log_error "pip3 not available for installation"
            enhanced_installation_error "pip3" "package_manager" "pip3 not found"
            return 1
        fi
    fi
    
    # Step 2: Test compose functionality
    log_step "2. Testing podman-compose functionality..."
    if ! test_compose_functionality "podman-compose"; then
        log_warning "podman-compose functionality test failed"
        
        # Step 2a: Try reinstalling with specific version
        log_step "2a. Attempting to fix by reinstalling podman-compose..."
        if command -v pip3 >/dev/null 2>&1; then
            log_step "Uninstalling current podman-compose..."
            pip3 uninstall -y podman-compose >/dev/null 2>&1 || true
            
            log_step "Installing podman-compose version 1.0.6..."
            if pip3 install podman-compose==1.0.6; then
                log_success "podman-compose 1.0.6 installed successfully"
                
                # Test again
                if test_compose_functionality "podman-compose"; then
                    log_success "podman-compose is now working correctly!"
                else
                    log_warning "podman-compose still not working after reinstall"
                fi
            else
                log_error "Failed to install podman-compose 1.0.6"
                enhanced_installation_error "podman-compose" "pip3" "version 1.0.6 installation failed"
            fi
        fi
    else
        log_success "podman-compose is working correctly!"
    fi
    
    # Step 3: Test native podman compose as alternative
    log_step "3. Testing native 'podman compose' as alternative..."
    if podman compose version >/dev/null 2>&1; then
        log_success "Native 'podman compose' is available"
        
        if test_compose_functionality "podman compose"; then
            log_success "Native 'podman compose' is working correctly!"
            echo ""
            log_step "💡 RECOMMENDATION: Use 'podman compose' instead of 'podman-compose'"
            echo "   You can set an alias: alias podman-compose='podman compose'"
        else
            log_warning "Native 'podman compose' exists but functionality test failed"
        fi
    else
        log_warning "Native 'podman compose' is not available"
        log_step "This may require a newer version of Podman (4.0+)"
    fi
    
    # Step 4: Check and fix SELinux issues
    log_step "4. Checking SELinux configuration (common RHEL 8 issue)..."
    check_and_fix_selinux
    
    # Step 5: Additional diagnostics
    log_step "5. Running additional diagnostics..."
    
    # Check Podman version
    if command -v podman >/dev/null 2>&1; then
        local podman_version
        podman_version=$(podman --version 2>/dev/null || echo "Unknown")
        log_step "Podman version: $podman_version"
    fi
    
    # Check Python version
    if command -v python3 >/dev/null 2>&1; then
        local python_version
        python_version=$(python3 --version 2>/dev/null || echo "Unknown")
        log_step "Python version: $python_version"
    fi
    
    # Check if user is in podman group or has proper subuid/subgid
    log_step "Checking rootless Podman configuration..."
    if [[ -f /etc/subuid ]] && [[ -f /etc/subgid ]]; then
        local user
        user=$(whoami)
        if grep -q "^${user}:" /etc/subuid && grep -q "^${user}:" /etc/subgid; then
            log_success "User $user has proper subuid/subgid configuration"
        else
            log_warning "User $user may need subuid/subgid configuration"
            echo "   Run: sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $user"
        fi
    fi
    
    # Final test with both options
    echo ""
    echo "🧪 Final Functionality Test"
    echo "==========================="
    
    local working_compose=""
    
    if command -v podman-compose >/dev/null 2>&1 && test_compose_functionality "podman-compose"; then
        working_compose="podman-compose"
        log_success "✅ podman-compose is working!"
    fi
    
    if podman compose version >/dev/null 2>&1 && test_compose_functionality "podman compose"; then
        if [[ -n "$working_compose" ]]; then
            working_compose="$working_compose and podman compose"
        else
            working_compose="podman compose"
        fi
        log_success "✅ podman compose is working!"
    fi
    
    echo ""
    if [[ -n "$working_compose" ]]; then
        echo "🎉 SUCCESS: Working compose implementations found: $working_compose"
        echo ""
        echo "📋 Next Steps:"
        echo "• Update your Easy_Splunk configuration to use the working compose command"
        echo "• Test cluster deployment: ./deploy.sh small"
        echo "• Run health checks: ./health_check.sh"
        echo ""
        echo "💡 TIP: If you have both working, 'podman compose' is recommended as it's native"
    else
        echo "❌ ISSUE: No working compose implementation found"
        echo ""
        echo "📋 Recommended Actions:"
        echo "1. Check the Enhanced Error messages above for specific troubleshooting steps"
        echo "2. Review system logs: journalctl -u podman --no-pager -n 50"
        echo "3. Try Docker as alternative: ./install-prerequisites.sh --runtime docker"
        echo "4. Contact support with the log file: $LOG_FILE"
        
        return 1
    fi
    
    return 0
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
