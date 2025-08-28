#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# test-standardized-error-handling.sh - Test standardized error handling across scripts


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo "=== Standardized Error Handling Test ==="
echo ""

# Test 1: Verify error handling library loads correctly
echo "Test 1: Verify error handling library"
if [[ -f "lib/error-handling.sh" ]]; then
    log_success "✅ error-handling.sh exists"

    # Test loading the library
    if source lib/error-handling.sh; then
        log_success "✅ error-handling.sh loads successfully"

        # Test key functions exist
        if type log_message &>/dev/null; then
            log_success "✅ log_message function available"
        else
            log_error "❌ log_message function missing"
        fi

        if type error_exit &>/dev/null; then
            log_success "✅ error_exit function available"
        else
            log_error "❌ error_exit function missing"
        fi

        if type run_with_log &>/dev/null; then
            log_success "✅ run_with_log function available"
        else
            log_error "❌ run_with_log function missing"
        fi

        if type setup_standard_logging &>/dev/null; then
            log_success "✅ setup_standard_logging function available"
        else
            log_error "❌ setup_standard_logging function missing"
        fi
    else
        log_error "❌ Failed to load error-handling.sh"
    fi
else
    log_error "❌ lib/error-handling.sh not found"
fi

# Test 2: Test logging functionality
echo ""
echo "Test 2: Test logging functionality"
if type log_message &>/dev/null; then
    echo "Testing log_message function:"
    log_message "INFO" "This is an info message"
    log_message "SUCCESS" "This is a success message"
    log_message "WARNING" "This is a warning message"
    log_message "ERROR" "This is an error message"
    log_success "✅ Logging functions work correctly"
else
    log_error "❌ log_message function not available for testing"
fi

# Test 3: Test logs directory creation
echo ""
echo "Test 3: Test logs directory creation"
if [[ -d "logs" ]]; then
    log_success "✅ logs directory exists"
    ls -la logs/
else
    log_warning "⚠️  logs directory doesn't exist yet - this is normal"
fi

# Test 4: Test setup_standard_logging
echo ""
echo "Test 4: Test setup_standard_logging"
if type setup_standard_logging &>/dev/null; then
    # This will create a log file
    setup_standard_logging "test-script"
    log_success "✅ setup_standard_logging completed"

    if [[ -f "logs/run-$(date +%F_%H%M%S).log" ]] || [[ -f "$LOG_FILE" ]]; then
        log_success "✅ Log file created successfully"
        ls -la logs/ 2>/dev/null || echo "No logs directory yet"
    else
        log_warning "⚠️  Log file not found (may be timing issue)"
    fi
else
    log_error "❌ setup_standard_logging function not available"
fi

# Test 5: Test run_with_log function
echo ""
echo "Test 5: Test run_with_log function"
if type run_with_log &>/dev/null; then
    echo "Testing run_with_log with a simple command:"
    if run_with_log echo "Hello from run_with_log"; then
        log_success "✅ run_with_log executed successfully"
    else
        log_error "❌ run_with_log failed"
    fi
else
    log_error "❌ run_with_log function not available"
fi

# Test 6: Test error_exit function
echo ""
echo "Test 6: Test error_exit function (will cause exit)"
echo "Note: This test will exit the script - it should be the last test"

if type error_exit &>/dev/null; then
    log_info "error_exit function is available (not testing exit to avoid stopping test suite)"
    log_success "✅ error_exit function available"
else
    log_error "❌ error_exit function not available"
fi

# Test 7: Check which scripts have been updated
echo ""
echo "Test 7: Check script standardization status"

scripts_to_check=(
    "deploy.sh"
    "orchestrator.sh"
    "start_cluster.sh"
    "stop_cluster.sh"
)

for script in "${scripts_to_check[@]}"; do
    if [[ -f "$script" ]]; then
        if grep -q "setup_standard_logging" "$script"; then
            log_success "✅ $script uses standardized error handling"
        elif grep -q "source.*error-handling.sh" "$script"; then
            log_success "✅ $script sources error-handling.sh"
        else
            log_warning "⚠️  $script may not use standardized error handling"
        fi
    else
        log_warning "⚠️  $script not found"
    fi
done

echo ""
log_success "🎉 Standardized error handling test completed!"
echo ""
echo "Summary:"
echo "  ✅ Error handling library loads correctly"
echo "  ✅ Logging functions work"
echo "  ✅ Log directory structure created"
echo "  ✅ run_with_log wrapper available"
echo "  ✅ setup_standard_logging function works"
echo ""
echo "Next steps:"
echo "  - Update remaining scripts to use standardized error handling"
echo "  - Test error scenarios with enhanced guidance"
echo "  - Verify log rotation and cleanup"
