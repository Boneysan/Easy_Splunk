#!/bin/bash
# Test script for with_retry function

source lib/error-handling.sh

echo "Testing with_retry function..."

# Test successful command
echo "Test 1: Successful command"
with_retry echo "Success!" && echo "✅ Test 1 passed"

# Test command with retries (will fail after 3 attempts)
echo "Test 2: Command that will fail"
with_retry --retries 2 false && echo "✅ Test 2 passed" || echo "❌ Test 2 failed as expected (exit code: $?)"

echo "with_retry function tests completed"

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test-with-retry"

# Set error handling
set -euo pipefail


