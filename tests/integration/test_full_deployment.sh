#!/usr/bin/env bash
#
# tests/integration/test_full_deployment.sh
# End-to-end release validation
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh,
#               generate-credentials.sh, generate-monitoring-config.sh, orchestrator.sh,
#               health_check.sh, stop_cluster.sh
# Version: 1.0.0
# ==============================================================================

# Intentionally avoid `set -e`; we want to capture failures and keep going.
set -uo pipefail
IFS=$'\n\t'

# --- Source deps ---
source "./lib/core.sh"
source "./lib/error-handling.sh"
source "./lib/runtime-detection.sh"
source "./lib/security.sh"
set +e  # neutralize strict -e set by core.sh

# --- Version Checks ---
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "test_full_deployment.sh requires security.sh version >= 1.0.0"
fi

TEST_COUNT=0
FAIL_COUNT=0
: "${SECRETS_DIR:=./secrets}"

# Detect runtime once for scoped checks
detect_container_runtime
read -r -a COMPOSE_COMMAND_ARRAY <<< "$COMPOSE_COMMAND"

# --- Tiny test harness ---

_run_cmd() { # _run_cmd "<shell command>"
  local out rc
  out="$(bash -o pipefail -c "$1" 2>&1)"; rc=$?
  printf '%s\0%d' "$out" "$rc"
}

assert_success() { # assert_success "description" "<shell command>"
  local desc="$1" cmd="$2"
  TEST_COUNT=$((TEST_COUNT+1))
  log_info "TEST: ${desc}"
  local blob out rc
  blob="$(_run_cmd "$cmd")"
  out="${blob%$'\0'*}"; rc="${blob##*$'\0'}"
  if [[ "$rc" -eq 0 ]]; then
    log_success "PASS: ${desc}"
  else
    log_error "FAIL: ${desc}"
    log_error "  -> Exit Code: ${rc}"
    printf '%s\n' "  -> Output:" >&2
    printf '%s\n' "$out" | sed 's/^/     /' >&2
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

# --- Environment setup/teardown ---

setup() {
  log_info "--- Preparing clean test environment ---"
  mkdir -p "${SECRETS_DIR}"
  harden_file_permissions "${SECRETS_DIR}" "700" "secrets directory" || true

  # Best-effort: stop any prior stack (with volumes) using compose if available
  if [[ -f docker-compose.yml ]]; then
    yes | "${COMPOSE_COMMAND_ARRAY[@]}" -f docker-compose.yml down --volumes --remove-orphans &>/dev/null || true
  fi

  # Also try your helper if present
  if [[ -x ./stop_cluster.sh ]]; then
    yes | ./stop_cluster.sh --with-volumes &>/dev/null || true
  fi

  # Remove generated artifacts
  rm -f docker-compose.yml
  rm -rf ./config ./management-scripts
  rm -f ./*.bak

  audit_security_configuration "./security-audit.txt"
  log_success "Environment is clean."
}

teardown() {
  log_info "--- Tearing down test environment ---"
  if [[ -f docker-compose.yml ]]; then
    "${COMPOSE_COMMAND_ARRAY[@]}" -f docker-compose.yml down --remove-orphans &>/dev/null || true
  fi
  if [[ -x ./stop_cluster.sh ]]; then
    ./stop_cluster.sh &>/dev/null || true
  fi
  harden_file_permissions "./config" "700" "config directory" || true
  harden_file_permissions "./docker-compose.yml" "600" "compose file" || true
  audit_security_configuration "./security-audit.txt"
  log_success "Teardown complete."
}

# --- The test flow ---

run_deployment_test() {
  log_info "--- Step 1: Credential & Monitoring Config Generation ---"
  assert_success "generate-credentials.sh runs successfully" \
    "yes | ./generate-credentials.sh"
  assert_success "generate-monitoring-config.sh runs successfully" \
    "yes | ./generate-monitoring-config.sh"

  log_info $'\n--- Step 2: Orchestration (timed) ---'
  local start_time end_time duration
  start_time=$(date +%s)
  assert_success "orchestrator.sh completes with monitoring enabled" \
    "./orchestrator.sh --with-monitoring"
  end_time=$(date +%s); duration=$((end_time - start_time))
  log_success "Orchestrator finished in ${duration} seconds."

  log_info $'\n--- Step 3: Cluster Health ---'
  log_info "Waiting 15 seconds for services to stabilize..."
  sleep 15
  assert_success "health_check.sh reports healthy" "./health_check.sh"

  log_info $'\n--- Step 4: App endpoint responds ---'
  assert_success "GET http://localhost:8080 returns 2xx" \
    "curl --fail --silent --max-time 10 http://localhost:8080 >/dev/null"

  log_info $'\n--- Step 5: Graceful shutdown ---'
  assert_success "stop_cluster.sh shuts the cluster down" "./stop_cluster.sh"

  log_info $'\n--- Step 6: Teardown verification (scoped to this compose) ---'
  if [[ -f docker-compose.yml ]]; then
    local leftover
    leftover="$("${COMPOSE_COMMAND_ARRAY[@]}" -f docker-compose.yml ps -q 2>/dev/null)"
    if [[ -z "$leftover" ]]; then
      log_success "PASS: No services remain for this compose project."
    else
      log_error "FAIL: Lingering services after shutdown: ${leftover//$'\n'/, }"
      FAIL_COUNT=$((FAIL_COUNT+1))
    fi
  else
    local names=(my_app_main my_app_redis my_app_prometheus my_app_grafana)
    local any_left=false
    for n in "${names[@]}"; do
      if "${CONTAINER_RUNTIME}" ps --format '{{.Names}}' | grep -q "^${n}\$"; then
        any_left=true
        log_error "  -> Still running: ${n}"
      fi
    done
    if [[ "$any_left" == "false" ]]; then
      log_success "PASS: No known app containers remain."
    else
      FAIL_COUNT=$((FAIL_COUNT+1))
    fi
  fi
}

main() {
  trap teardown EXIT INT TERM
  setup
  run_deployment_test

  log_info $'\n--- Integration Test Summary ---'
  if (( FAIL_COUNT == 0 )); then
    log_success "✅ All ${TEST_COUNT} integration tests passed!"
    exit 0
  else
    log_error "❌ ${FAIL_COUNT} of ${TEST_COUNT} integration tests failed."
    exit 1
  fi
}

TEST_FULL_DEPLOYMENT_VERSION="1.0.0"
main