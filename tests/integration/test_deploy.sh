#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/integration/test_deploy.sh
# Integration tests for deploy.sh, covering full deployment workflow.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, lib/runtime-detection.sh, lib/security.sh,
#               generate-credentials.sh, generate-monitoring-config.sh, orchestrator.sh,
#               health_check.sh, generate-splunk-configs.sh, resolve-digests.sh,
#               integration-guide.sh, deploy.sh
# Version: 1.0.1
# ==============================================================================

# Intentionally avoid `set -e`; we want to capture failures and keep going.

# --- Source deps ---
source "./lib/core.sh"
source "./lib/error-handling.sh"
source "./lib/runtime-detection.sh"
source "./lib/security.sh"
set +e  # neutralize strict -e set by core.sh

# --- Version Checks ---
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "test_deploy.sh requires security.sh version >= 1.0.0"
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
  mkdir -p "${SECRETS_DIR}" "./config"
  harden_file_permissions "${SECRETS_DIR}" "700" "secrets directory" || true
  harden_file_permissions "./config" "700" "config directory" || true

  # Create mock config and versions.env
  mkdir -p "./config-templates"
  cat > "./config-templates/small-production.conf" <<EOF
INDEXER_COUNT=2
SEARCH_HEAD_COUNT=1
ENABLE_MONITORING=true
CPU_INDEXER="2"
MEMORY_INDEXER="4G"
CPU_SEARCH_HEAD="1"
MEMORY_SEARCH_HEAD="2G"
EOF
  cat > "./versions.env" <<EOF
readonly APP_IMAGE_REPO=nginx
readonly APP_VERSION=latest
EOF
  harden_file_permissions "./config-templates/small-production.conf" "600" "small config" || true
  harden_file_permissions "./versions.env" "600" "versions file" || true

  # Best-effort: stop any prior stack
  if [[ -f docker-compose.yml ]]; then
    yes | "${COMPOSE_COMMAND_ARRAY[@]}" -f docker-compose.yml down --volumes --remove-orphans &>/dev/null || true
  fi
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
run_deploy_test() {
  log_info "--- Step 1: Deploy small cluster ---"
  assert_success "deploy.sh small runs successfully" \
    "yes | ./deploy.sh small --index-name test_index --splunk-user admin --splunk-password testpass"

  log_info $'\n--- Step 2: Deploy with legacy config ---'
  cat > "./old.env" <<EOF
DOCKER_IMAGE_TAG=latest
EOF
  assert_success "deploy.sh with legacy config check" \
    "yes | ./deploy.sh small --config-file ./old.env"

  log_info $'\n--- Step 3: Deploy with --no-monitoring ---'
  assert_success "deploy.sh with no monitoring" \
    "yes | ./deploy.sh small --no-monitoring"

  log_info $'\n--- Step 4: Deploy with --skip-digests ---'
  assert_success "deploy.sh with skip digests" \
    "yes | ./deploy.sh small --skip-digests"

  log_info $'\n--- Step 5: Cluster Health ---'
  log_info "Waiting 15 seconds for services to stabilize..."
  sleep 15
  assert_success "health_check.sh reports healthy" "./health_check.sh"

  log_info $'\n--- Step 6: App endpoint responds ---'
  assert_success "GET http://localhost:8000 returns 2xx" \
    "curl --fail --silent --max-time 10 http://localhost:8000 >/dev/null"

  log_info $'\n--- Step 7: Graceful shutdown ---'
  assert_success "stop_cluster.sh shuts the cluster down" "./stop_cluster.sh"
}

main() {
  trap teardown EXIT INT TERM
  setup
  run_deploy_test

  log_info $'\n--- Integration Test Summary ---'
  if (( FAIL_COUNT == 0 )); then
    log_success "✅ All ${TEST_COUNT} integration tests passed!"
    exit 0
  else
    log_error "❌ ${FAIL_COUNT} of ${TEST_COUNT} integration tests failed."
    exit 1
  fi
}

TEST_DEPLOY_VERSION="1.0.1"
main

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "test_deploy"

# Set error handling


