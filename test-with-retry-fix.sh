#!/bin/bash
# test-with-retry-fix.sh - Test the fixed with_retry function

set -euo pipefail

echo "🧪 Testing with_retry function fix..."

# Source just the fallback functions from install-prerequisites.sh
source <(grep -A 50 "Fallback with_retry function" /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/install-prerequisites.sh | head -40)

# Test 1: Basic with_retry functionality
echo "Test 1: Basic with_retry (should succeed)"
if with_retry echo "Hello World"; then
    echo "✅ Basic with_retry works"
else
    echo "❌ Basic with_retry failed"
fi

# Test 2: with_retry with --retries argument
echo ""
echo "Test 2: with_retry with --retries (should succeed)"
if with_retry --retries 2 -- echo "Hello with retries"; then
    echo "✅ with_retry --retries works"
else
    echo "❌ with_retry --retries failed"
fi

# Test 3: with_retry with failing command (should retry and fail)
echo ""
echo "Test 3: with_retry with failing command (should retry 2 times then fail)"
if with_retry --retries 2 -- false; then
    echo "❌ Should have failed but didn't"
else
    echo "✅ with_retry correctly failed after retries"
fi

echo ""
echo "🎉 All with_retry tests completed!"
