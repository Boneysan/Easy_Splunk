#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt


# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_monitoring"

# Set error handling
```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_monitoring.sh
# Unit tests for monitoring.sh, covering Prometheus and Grafana config generation.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/monitoring.sh
# Version: 1.0.0
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/core.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../lib/monitoring.sh"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

# Mock commands
date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
stat() { echo "644"; return 0; }

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

# Test 1: Basic Prometheus config
test_prometheus_config() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  PROMETHEUS_CONFIG_FILE="$tmp/prometheus.yml" generate_monitoring_config
  [[ -f "$tmp/prometheus.yml" ]] || return 1
  grep -q "job_name: 'prometheus'" "$tmp/prometheus.yml" && \
  grep -q "job_name: 'app'" "$tmp/prometheus.yml"
}

# Test 2: Prometheus rules
test_prometheus_rules() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  PROMETHEUS_RULES_FILE="$tmp/alert.rules.yml" generate_monitoring_config
  [[ -f "$tmp/alert.rules.yml" ]] && grep -q "alert: InstanceDown" "$tmp/alert.rules.yml"
}

# Test 3: Grafana datasource
test_grafana_datasource() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  GRAFANA_DATASOURCE_FILE="$tmp/datasource.yml" generate_monitoring_config
  [[ -f "$tmp/datasource.yml" ]] && grep -q "name: Prometheus" "$tmp/datasource.yml"
}

# Test 4: Grafana dashboard provider
test_grafana_dashboard_provider() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  GRAFANA_DASHBOARD_PROVIDER_FILE="$tmp/provider.yml" generate_monitoring_config
  [[ -f "$tmp/provider.yml" ]] && grep -q "name: 'default'" "$tmp/provider.yml"
}

# Test 5: Placeholder dashboard
test_placeholder_dashboard() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  GRAFANA_DASHBOARDS_DIR="$tmp/dashboards" generate_monitoring_config
  [[ -f "$tmp/dashboards/app-overview.json" ]] && grep -q "title: \"App Overview\"" "$tmp/dashboards/app-overview.json"
}

# Test 6: Splunk targets
test_splunk_targets() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  SPLUNK_INDEXER_COUNT=2 SPLUNK_SEARCH_HEAD_COUNT=1 PROMETHEUS_CONFIG_FILE="$tmp/prometheus.yml" generate_monitoring_config
  [[ -f "$tmp/prometheus.yml" ]] && grep -q "splunk-idx1:8089" "$tmp/prometheus.yml" && \
  grep -q "splunk-sh1:8089" "$tmp/prometheus.yml"
}

# Run all tests
run_test "Basic Prometheus config" test_prometheus_config
run_test "Prometheus rules" test_prometheus_rules
run_test "Grafana datasource" test_grafana_datasource
run_test "Grafana dashboard provider" test_grafana_dashboard_provider
run_test "Placeholder dashboard" test_placeholder_dashboard
run_test "Splunk targets" test_splunk_targets

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```

