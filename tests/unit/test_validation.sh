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
PROJECT_ROOT="${TEST_DIR}/../../"

# Source libs. Note: core.sh sets -e; disable it afterwards for test harness.
source "${PROJECT_ROOT}/lib/core.sh"
source "${PROJECT_ROOT}/lib/error-handling.sh"
source "${PROJECT_ROOT}/lib/validation.sh"
set +e  # neutralize strict -e that core.sh enabled

# --- Minimal Test Framework ---
TEST_COUNT=0
FAIL_COUNT=0

_pass() { log_success "PASS: $1"; }
_fail() { log_error   "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# Runs a command in a subshell (clean env for -e behavior differences)
# assert_success "desc" cmd args...
assert_success() {
  local desc="$1"; shift
  TEST_COUNT=$((TEST_COUNT+1))
  ( set +e; "$@" ) &>/dev/null
  local rc=$?
  if [[ $rc -eq 0 ]]; then _pass "$desc"; else _fail "$desc"; fi
}

# Runs a command in a subshell with `set -e` so any non-zero (e.g., mocked die)
# aborts the subshell and returns failure (what we want to detect).
# assert_fail "desc" cmd args...
assert_fail() {
  local desc="$1"; shift
  TEST_COUNT=$((TEST_COUNT+1))
  ( set -e; "$@" ) &>/dev/null
  local rc=$?
  if [[ $rc -ne 0 ]]; then _pass "$desc"; else _fail "$desc"; fi
}

# --- Mocks / Stubs ---
# Make die() non-exiting but return the code so `set -e` contexts fail as desired.
die() { return "$1"; }

# Stable host values for resource validation
get_total_memory() { echo 8192; }  # 8 GiB
get_cpu_cores()    { echo 4;    }

# --- Test Cases ---

test_validate_system_resources() {
  log_info $'\n--- validate_system_resources ---'
  assert_success "passes when resources are sufficient" \
    validate_system_resources 4096 2
  assert_success "passes when resources are exactly sufficient" \
    validate_system_resources 8192 4
  assert_fail "fails when memory is insufficient" \
    validate_system_resources 9000 4
  assert_fail "fails when CPU cores are insufficient" \
    validate_system_resources 8192 8
  # Edge cases
  assert_fail "fails on zero RAM requirement (reject nonsensical input)" \
    validate_system_resources 0 2
  assert_fail "fails on negative CPU cores (reject nonsensical input)" \
    validate_system_resources 4096 -1
}

test_validate_required_var() {
  log_info $'\n--- validate_required_var ---'
  assert_success "passes for a non-empty string" \
    validate_required_var "some_value" "Test Var"
  assert_fail "fails for an empty string" \
    validate_required_var "" "Test Var"
  assert_fail "fails for a string with only spaces" \
    validate_required_var "   " "Test Var"
}

test_validate_configuration_compatibility() {
  log_info $'\n--- validate_configuration_compatibility ---'
  # Smoke test; function currently only logs success
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
