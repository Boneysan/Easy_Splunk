#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"

echo "Starting test..."

# Test logging
echo "Testing log_info..."
output=$(log_info "Test info" 2>&1)
echo "log_info output: $output"
if [[ "$output" =~ "\[INFO\]" ]]; then
  echo "✓ log_info test passed"
else
  echo "✗ log_info test failed"
  exit 1
fi

echo "All manual tests passed!"
