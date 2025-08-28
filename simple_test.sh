#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"

echo "Testing log_info..."
log_info "Test info"
echo "Success!"

echo "Testing DEBUG log_debug..."
DEBUG=true log_debug "Test debug"
echo "Success!"

echo "All tests passed!"
