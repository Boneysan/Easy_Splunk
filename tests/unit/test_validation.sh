#!/usr/bin/env bash
#
# tests/unit/test_validation.sh
#
# Unit tests for lib/validation.sh
# ==============================================================================

# --- Test Shell Options ---
# Intentionally do NOT enable `set -e`. We want to observe failures.
set -uo pipefail

# --- Source Dependencies ---
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
PROJECT_ROOT="$(cd "${TEST_DIR}/../../" && pwd)"

# Source libs. Note: core.sh may set -e; disable it afterwards for test harness.
# shellcheck source=../../lib/core.sh
source "${PROJECT_ROOT}/lib/core.sh"
# shellcheck source=../../lib/error-handling.sh
source "${PROJECT_ROOT}/lib/error-handling.sh"
# shellcheck source=../../lib/validation.sh
source "${PROJECT_ROOT}/lib/validation.sh"
set +e  # neutralize strict -e that core.sh might have enabled

# --- Minimal Test Framework ---
TEST_COUNT=0
FAIL_COUNT=0

_pass() { log_success "PASS: $1"; }
_fail() { log_error   "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# Run and expect success (rc==0)
assert_success() {
  local desc="$1"; shift
  TEST_COUNT=$((TEST_COUNT+1))
  ( set +e; "$@" ) &>/dev/null
  local rc=$?
  if [[ $rc -eq 0 ]]; then _pass "$desc"; else _fail "$desc (rc=$rc)"; fi
}

# Run and expect failure (rc!=0). Uses `set -e` to ensure die() or any nonzero aborts.
assert_fail() {
  local desc="$1"; shift
  TEST_COUNT=$((TEST_COUNT+1))
  ( set -e; "$@" ) &>/dev/null
  local rc=$?
  if [[ $rc -ne 0 ]]; then _pass "$desc"; else _fail "$desc (unexpected success)"; fi
}

# Run and assert exact return code (no -e so we can capture rc precisely)
assert_rc() {
  local desc="$1" expect="$2"; shift 2
  TEST_COUNT=$((TEST_COUNT+1))
  ( set +e; "$@" ) &>/dev/null
  local rc=$?
  if [[ $rc -eq $expect ]]; then _pass "$desc"; else _fail "$desc (rc=$rc, expected=$expect)"; fi
}

# --- Mocks / Stubs ---
# Make die() non-exiting but return the code so assertions can check rc.
die() { return "$1"; }

# Provide stable host values for resource validation
get_total_memory() { echo 8192; }  # 8 GiB
get_cpu_cores()    { echo 4;    }

# --- Sanity checks (functions exist) ---
require_funcs=( validate_system_resources validate_required_var validate_configuration_compatibility )
for f in "${require_funcs[@]}"; do
  if ! declare -F "$f" >/dev/null; then
    log_error "Missing function: $f"
    exit 1
  fi
done

# --- Test Cases ---

test_validate_system_resources() {
  log_info $'\n--- validate_system_resources ---'
  # happy paths
  assert_success "passes when resources are sufficient" \
    validate_system_resources 4096 2
  assert_success "passes when resources are exactly sufficient" \
    validate_system_resources 8192 4

  # resource shortfall
  assert_fail "fails when memory is insufficient" \
    validate_system_resources 9000 4
  assert_fail "fails when CPU cores are insufficient" \
    validate_system_resources 8192 8

  # input validation (nonsensical values)
  assert_fail "fails on zero RAM requirement" \
    validate_system_resources 0 2
  assert_fail "fails on negative CPU cores" \
    validate_system_resources 4096 -1
  assert_fail "fails on non-numeric RAM" \
    validate_system_resources notanumber 2
  assert_fail "fails on non-numeric CPU" \
    validate_system_resources 4096 nope
}

test_validate_required_var() {
  log_info $'\n--- validate_required_var ---'
  assert_success "passes for a normal non-empty string" \
    validate_required_var "some_value" "Test Var"
  assert_success "passes for value containing spaces" \
    validate_required_var "value with spaces" "Test Var"
  assert_fail "fails for an empty string" \
    validate_required_var "" "Test Var"
  assert_fail "fails for a string with only spaces" \
    validate_required_var "   " "Test Var"
}

test_validate_configuration_compatibility() {
  log_info $'\n--- validate_configuration_compatibility ---'
  # Smoke test; function currently only logs success (should not error)
  assert_success "runs without error" \
    validate_configuration_compatibility
}

# --- Runner ---
main() {
  log_info "Running Unit Tests for lib/validation.sh"

  test_validate_system_resources
  test_validate_required_var
  test_validate_configuration_compatibility

  log_info $'\n--- Test Summary ---'
  if (( FAIL_COUNT == 0 )); then
    log_success "✅ All ${TEST_COUNT} tests passed!"
    exit 0
  else
    log_error "❌ ${FAIL_COUNT} of ${TEST_COUNT} tests failed."
    exit 1
  fi
}

main
