

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_generate_monitoring_config"

# Set error handling
set -euo pipefail
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_generate_monitoring_config.sh
# Unit tests for generate-monitoring-config.sh, covering Prometheus and Grafana
# config generation with CLI options.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/security.sh, lib/monitoring.sh,
#               generate-monitoring-config.sh
# Version: 1.0.0
# ==============================================================================
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/security.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/monitoring.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../generate-monitoring-config.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "644"; return 0; }
read() { echo "y"; } # Auto-confirm
openssl() { echo "Mock openssl: $@"; return 0; }

# Helper to run a test
run_test() {
  local test_name="$1"; shift
  ((TEST_COUNT++))
  log_info "Running test: ${test_name}"
  if "$@"; then
    log_success "Test passed: ${test_name}"
    ((TEST_PASSED++))
  else
    log_error "Test failed: ${test_name}"
    ((TEST_FAILED++))
  fi
}

# Test 1: Basic config generation
test_basic_config() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ROOT_DIR="$tmp" main --yes
  [[ -f "$tmp/config/prometheus.yml" ]] && \
  [[ -f "$tmp/config/alert.rules.yml" ]] && \
  [[ -f "$tmp/config/grafana-provisioning/datasources/datasource.yml" ]] && \
  [[ -f "$tmp/config/grafana-provisioning/dashboards/provider.yml" ]] && \
  [[ -f "$tmp/config/grafana-provisioning/dashboards/app-overview.json" ]]
}

# Test 2: Custom root directory
test_custom_root() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ROOT_DIR="$tmp/custom" main --yes
  [[ -f "$tmp/custom/config/prometheus.yml" ]] && \
  grep -q "job_name: 'app'" "$tmp/custom/config/prometheus.yml"
}

# Test 3: Splunk targets
test_splunk_targets() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ROOT_DIR="$tmp" main --yes --splunk-indexers 2 --splunk-search-heads 1
  [[ -f "$tmp/config/prometheus.yml" ]] && \
  grep -q "splunk-idx1:8089" "$tmp/config/prometheus.yml" && \
  grep -q "splunk-sh1:8089" "$tmp/config/prometheus.yml"
}

# Test 4: No placeholder dashboard
test_no_placeholder() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ROOT_DIR="$tmp" main --yes --no-placeholder
  [[ ! -f "$tmp/config/grafana-provisioning/dashboards/app-overview.json" ]]
}

# Test 5: Dry run
test_dry_run() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ROOT_DIR="$tmp" main --dry-run | grep -q "Scrape Interval:.*15s"
  [[ ! -d "$tmp/config" ]]
}

# Test 6: Custom targets
test_custom_targets() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ROOT_DIR="$tmp" main --yes --redis-target "redis:9121" --extra-targets "svc1:1234,svc2:5678"
  [[ -f "$tmp/config/prometheus.yml" ]] && \
  grep -q "job_name: 'redis-exporter'" "$tmp/config/prometheus.yml" && \
  grep -q "svc1:1234" "$tmp/config/prometheus.yml"
}

# Run all tests
run_test "Basic config generation" test_basic_config
run_test "Custom root directory" test_custom_root
run_test "Splunk targets" test_splunk_targets
run_test "No placeholder dashboard" test_no_placeholder
run_test "Dry run" test_dry_run
run_test "Custom targets" test_custom_targets

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

