```bash
#!/usr/bin/env bash
# ==============================================================================
# tests/unit/test_compose_generator.sh
# Unit tests for compose-generator.sh, covering Compose file and env template generation.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#               lib/validation.sh, lib/compose-generator.sh
# ==============================================================================
set -euo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Source dependencies
for script in core.sh error-handling.sh versions.sh validation.sh compose-generator.sh; do
  # shellcheck source=/dev/null
  source "${SCRIPT_DIR}/../../lib/${script}"
done
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../versions.env"

# Test counter and results
TEST_COUNT=0
TEST_PASSED=0
TEST_FAILED=0

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

# Test 1: Generate basic Compose file
test_generate_compose_basic() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  generate_compose_file "$tmp/docker-compose.yml"
  [[ -f "$tmp/docker-compose.yml" ]] && grep -q "app:" "$tmp/docker-compose.yml"
}

# Test 2: Generate Compose with Splunk
test_generate_compose_splunk() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  ENABLE_SPLUNK=true SPLUNK_PASSWORD="test12345" SPLUNK_SECRET="secret" \
  INDEXER_COUNT=2 SEARCH_HEAD_COUNT=1 \
  generate_compose_file "$tmp/docker-compose.yml"
  grep -q "splunk-idx1:" "$tmp/docker-compose.yml" && grep -q "splunk-sh1:" "$tmp/docker-compose.yml"
}

# Test 3: Generate env template
test_generate_env_template() {
  local tmp=$(mktemp -d)
  register_cleanup "rm -rf '$tmp'"
  generate_env_template "$tmp/.env"
  [[ -f "$tmp/.env" ]] && grep -q "COMPOSE_PROJECT_NAME" "$tmp/.env"
}

# Test 4: Validate Compose config
test_validate_compose_config() {
  ENABLE_SPLUNK=true SPLUNK_PASSWORD="test12345" SPLUNK_SECRET="secret" \
  validate_compose_config
}

# Run all tests
run_test "Generate basic Compose file" test_generate_compose_basic
run_test "Generate Compose with Splunk" test_generate_compose_splunk
run_test "Generate env template" test_generate_env_template
run_test "Validate Compose config" test_validate_compose_config

# Summary
log_info "Test summary: ${TEST_PASSED} passed, ${TEST_FAILED} failed, ${TEST_COUNT} total"
[[ ${TEST_FAILED} -eq 0 ]]
```