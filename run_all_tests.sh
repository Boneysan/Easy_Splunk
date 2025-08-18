#!/usr/bin/env bash
# ==============================================================================
# run_all_tests.sh
# Master script to run all unit and integration tests for the Splunk cluster orchestrator project.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#               lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#               lib/security.sh, lib/monitoring.sh, lib/parse-args.sh, lib/air-gapped.sh,
#               lib/universal-forwarder.sh, lib/platform-helpers.sh, orchestrator.sh,
#               generate-credentials.sh, generate-monitoring-config.sh, create-airgapped-bundle.sh,
#               airgapped-quickstart.sh, generate-selinux-helpers.sh, podman-docker-setup.sh,
#               start_cluster.sh, stop_cluster.sh, health_check.sh, backup_cluster.sh,
#               restore_cluster.sh, generate-management-scripts.sh, generate-splunk-configs.sh,
#               verify-bundle.sh, resolve-digests.sh, integration-guide.sh, install-prerequisites.sh,
#               deploy.sh, tests/unit/test_*.sh, tests/integration/test_*.sh
# Version: 1.0.21
# ==============================================================================
# --- Strict Mode & Setup --------------------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# --- Source Core Dependencies ---------------------------------------------------
# shellcheck source=lib/core.sh
source "${REPO_ROOT}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${REPO_ROOT}/lib/error-handling.sh"

# --- Main Functions ----------------------------------------------------------
main() {
    log_info "Starting test suite execution"
    
    # Run security vulnerability scan
    if ! run_security_scan; then
        log_error "Security vulnerability scan failed"
        exit 1
    fi
    
    # Run unit tests
    if ! run_unit_tests; then
        log_error "Unit tests failed"
        exit 1
    fi
    
    # Run integration tests
    if ! run_integration_tests; then
        log_error "Integration tests failed"
        exit 1
    fi
    
    # Run performance tests if enabled
    if ! run_performance_tests; then
        log_error "Performance tests failed"
        exit 1
    fi
    
    log_success "All tests completed successfully"
    return 0
}

print_usage() {
    cat << EOF
Usage: $0 [options]

Options:
    -v, --verbose           Enable verbose output
    -f, --filter PATTERN    Only run tests matching PATTERN
    -p, --performance      Run performance tests (takes longer)
    -s, --skip-long        Skip long-running tests
    --skip-security        Skip security vulnerability scan
    -h, --help             Show this help message
EOF
}

# --- Defaults / Flags -----------------------------------------------------------
VERBOSE=false
TEST_FILTER=""
RUN_PERFORMANCE_TESTS=false
SKIP_LONG_TESTS=false
SKIP_SECURITY_SCAN=false

# --- Test Suite Functions -----------------------------------------------------
run_unit_tests() {
    log_section "Running Unit Tests"
    
  local unit_tests_dir="${REPO_ROOT}/tests/unit"
    local test_files=()
    
    while IFS= read -r -d '' file; do
        test_files+=("$file")
    done < <(find "${unit_tests_dir}" -name "test_*.sh" -type f -print0)
    
    for test_file in "${test_files[@]}"; do
        if [[ -n "${TEST_FILTER}" ]] && ! [[ "$(basename "${test_file}")" =~ ${TEST_FILTER} ]]; then
            continue
        fi
        
        log_info "Running test: $(basename "${test_file}")"
        if ! "${test_file}"; then
            log_error "Unit test failed: ${test_file}"
            return 1
        fi
    done
    
    log_success "All unit tests passed"
    return 0
}

run_integration_tests() {
    log_section "Running Integration Tests"
    
    # Run cluster size tests
    if ! [[ "${SKIP_LONG_TESTS}" == "true" ]]; then
        log_info "Running cluster size tests..."
      if ! "${REPO_ROOT}/tests/integration/test_cluster_sizes.sh"; then
            log_error "Cluster size tests failed"
            return 1
        fi
    else
        log_info "Skipping cluster size tests (--skip-long specified)"
    fi
    
    # Run monitoring stack tests
    log_info "Running monitoring stack tests..."
  if ! "${REPO_ROOT}/tests/integration/test_monitoring_stack.sh"; then
        log_error "Monitoring stack tests failed"
        return 1
    fi
    
    # Run failure scenario tests
    if ! [[ "${SKIP_LONG_TESTS}" == "true" ]]; then
        log_info "Running failure scenario tests..."
  if ! "${REPO_ROOT}/tests/integration/test_failure_scenarios.sh"; then
            log_error "Failure scenario tests failed"
            return 1
        fi
    else
        log_info "Skipping failure scenario tests (--skip-long specified)"
    fi
    
    log_success "All integration tests passed"
    return 0
}

run_performance_tests() {
    if ! [[ "${RUN_PERFORMANCE_TESTS}" == "true" ]]; then
        log_info "Skipping performance tests (use --performance to run them)"
        return 0
    fi
    
    log_section "Running Performance Tests"
    
  if ! "${REPO_ROOT}/tests/performance/test_regression.sh"; then
        log_error "Performance regression tests failed"
        return 1
    fi
    
    log_success "All performance tests passed"
    return 0
}

run_security_scan() {
    if [[ "${SKIP_SECURITY_SCAN}" == "true" ]]; then
        log_info "Skipping security vulnerability scan"
        return 0
    fi
    
    log_section "Running Security Vulnerability Scan"
    
  if ! "${REPO_ROOT}/tests/security/security_scan.sh"; then
        log_error "Security vulnerability scan failed"
        return 1
    fi
    
    log_success "Security vulnerability scan passed"
    return 0
}
RUN_UNIT=true
RUN_INTEGRATION=true
# --- CLI Parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -f|--filter)
      TEST_FILTER="${2:?filter required}"
      shift 2
      ;;
    -p|--performance)
      RUN_PERFORMANCE_TESTS=true
      shift
      ;;
    -s|--skip-long)
      SKIP_LONG_TESTS=true
      shift
      ;;
    --skip-security)
      SKIP_SECURITY_SCAN=true
      shift
      ;;
    --unit-only)
      RUN_INTEGRATION=false
      shift
      ;;
    --integration-only)
      RUN_UNIT=false
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]
Runs all unit and integration tests for the Splunk cluster orchestrator project.
Options:
  -v, --verbose         Enable verbose output (sets DEBUG=true)
  --filter REGEX        Only run test scripts matching REGEX
  --unit-only           Run only unit tests
  --integration-only    Run only integration tests
  -h, --help            Show this help and exit
Examples:
  $(basename "$0")                     # Run all tests
  $(basename "$0") --verbose           # Run all tests with verbose output
  $(basename "$0") --filter validation # Run tests matching 'validation'
  $(basename "$0") --unit-only         # Run only unit tests
EOF
      exit 0
      ;;
    *)
      log_warn "Unknown argument: $1"
      shift
      ;;
  esac
done
# --- Setup ----------------------------------------------------------------------
# Enable debug logging if verbose
if is_true "${VERBOSE}"; then
  export DEBUG=true
fi
# Discover test scripts
UNIT_TEST_SCRIPTS=()
INTEGRATION_TEST_SCRIPTS=()
if is_true "${RUN_UNIT}"; then
  while IFS= read -r script; do
    UNIT_TEST_SCRIPTS+=("$script")
  done < <(find "${REPO_ROOT}/tests/unit" -type f -name "test_*.sh" | sort)
fi
if is_true "${RUN_INTEGRATION}"; then
  while IFS= read -r script; do
    INTEGRATION_TEST_SCRIPTS+=("$script")
  done < <(find "${REPO_ROOT}/tests/integration" -type f -name "test_*.sh" | sort)
fi
# Filter test scripts if specified
if [[ -n "${TEST_FILTER}" ]]; then
  filtered_unit_scripts=()
  for script in "${UNIT_TEST_SCRIPTS[@]}"; do
    if [[ "$(basename "${script}")" =~ ${TEST_FILTER} ]]; then
      filtered_unit_scripts+=("${script}")
    fi
  done
  UNIT_TEST_SCRIPTS=("${filtered_unit_scripts[@]}")
fi
# Global test counters
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
# --- Helpers --------------------------------------------------------------------
run_test_script() {
  local script="$1" is_integration="${2:-false}"
  local script_name
  script_name=$(basename "${script}")
  log_info "Running test script: ${script_name} ($(date)) at ${script}"
  # Define step stubs if not present
  type begin_step >/dev/null 2>&1 || begin_step() { :; }
  type complete_step >/dev/null 2>&1 || complete_step() { :; }
  begin_step "test_${script_name}"
  # Run in a subshell to avoid state pollution
  (
    # Source dependencies (ordered to satisfy guards); exclude non-existent lib/parse-args.sh
    for dep in core.sh error-handling.sh validation.sh versions.sh runtime-detection.sh compose-generator.sh security.sh monitoring.sh air-gapped.sh universal-forwarder.sh platform-helpers.sh; do
      # shellcheck source=/dev/null
      source "${REPO_ROOT}/lib/${dep}"
    done
    # Source top-level scripts that are not under lib
  for top in orchestrator.sh generate-credentials.sh generate-monitoring-config.sh create-airgapped-bundle.sh airgapped-quickstart.sh generate-selinux-helpers.sh podman-docker-setup.sh start_cluster.sh stop_cluster.sh health_check.sh backup_cluster.sh restore_cluster.sh generate-management-scripts.sh generate-splunk-configs.sh verify-bundle.sh resolve-digests.sh integration-guide.sh install-prerequisites.sh deploy.sh parse-args.sh; do
      # shellcheck source=/dev/null
      source "${REPO_ROOT}/${top}"
    done
    if [[ -f "${REPO_ROOT}/versions.env" ]]; then
      # shellcheck source=/dev/null
      # Normalize CRLF if any by filtering through sed in a subshell
      source <(sed 's/\r$//' "${REPO_ROOT}/versions.env")
    else
      log_error "versions.env not found"
      exit 1
    fi
    # Mock system commands for unit tests only
    if [[ "$is_integration" == "false" ]]; then
      CONTAINER_RUNTIME="docker"
      COMPOSE_IMPL="docker-compose"
      COMPOSE_SUPPORTS_SECRETS=1
      COMPOSE_SUPPORTS_HEALTHCHECK=1
      COMPOSE_SUPPORTS_PROFILES=1
      COMPOSE_PS_JSON_SUPPORTED=1
      export CONTAINER_RUNTIME COMPOSE_IMPL COMPOSE_SUPPORTS_SECRETS COMPOSE_SUPPORTS_HEALTHCHECK COMPOSE_SUPPORTS_PROFILES COMPOSE_PS_JSON_SUPPORTED
      compose() { echo "Mock compose: $@" >&2; return 0; }
      docker() { echo "Mock docker: $@" >&2; return 0; }
      podman() { echo "Mock podman: $@" >&2; return 0; }
      get_total_memory() { echo "8192"; }
      get_cpu_cores() { echo "4"; }
      df() { echo "100GB"; return 0; }
      ss() { return 1; } # Port free
      openssl() { echo "Mock openssl: $@" >&2; return 0; }
      date() { echo "2025-08-13 12:00:00 UTC"; return 0; }
      stat() { echo "600"; return 0; }
      read() { echo "y"; } # Auto-confirm for scripts
      curl() { echo "Mock curl: $@"; touch "$4" 2>/dev/null; return 0; }
      sha256sum() { echo "abc123"; return 0; }
      uname() { echo "x86_64"; }
      get_os() { echo "linux"; }
      firewall-cmd() { echo "Mock firewall-cmd: $@"; return 0; }
      systemctl() { echo "Mock systemctl: $@"; return 0; }
      dnf() { echo "Mock dnf: $@"; return 0; }
      yum() { echo "Mock yum: $@"; return 0; }
      apt_get() { echo "Mock apt-get: $@"; return 0; }
      brew() { echo "Mock brew: $@"; return 0; }
      getenforce() { echo "enforcing"; return 0; }
      sestatus() { echo "SELinux status: enforcing"; return 0; }
      setsebool() { echo "Mock setsebool: $@"; return 0; }
      semanage() { echo "Mock semanage: $@"; return 0; }
      restorecon() { echo "Mock restorecon: $@"; return 0; }
      sudo() { "$@"; } # Bypass sudo for mocks
      cat() { echo "ID=rhel" > /etc/os-release; } # Mock RHEL-like system
      jq() { echo "Mock jq: $@"; return 0; }
      gpg() { echo "Mock gpg: $@"; touch "$6"; return 0; }
      tar() { echo "Mock tar: $@"; touch "$4"; return 0; }
      shellcheck() { echo "Mock shellcheck: $@"; return 0; }
      tree() { echo "Mock tree: $@"; return 0; }
    fi
    # Run the test script
    if bash "${script}"; then
      complete_step "test_${script_name}"
      return 0
    else
      complete_step "test_${script_name}"
      return 1
    fi
  )
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    ((TOTAL_PASSED++))
  else
    ((TOTAL_FAILED++))
  fi
  ((TOTAL_TESTS++))
  return $rc
}
# --- Main -----------------------------------------------------------------------
main() {
  _show_banner() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║ SPLUNK CLUSTER ORCHESTRATOR TEST SUITE                                       ║
║                                                                              ║
║ Runs all unit and integration tests for the Splunk cluster orchestrator project║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
  }
  _show_banner
  log_info "🚀 Starting test suite ($(date))..."
  # Validate test scripts exist
  if [[ ${#UNIT_TEST_SCRIPTS[@]} -eq 0 && ${#INTEGRATION_TEST_SCRIPTS[@]} -eq 0 ]]; then
  log_error "No test scripts found in ${REPO_ROOT}/tests/unit or ${REPO_ROOT}/tests/integration"
    exit 1
  fi
  # List unit tests
  if is_true "${RUN_UNIT}"; then
    log_info "Running ${#UNIT_TEST_SCRIPTS[@]} unit test scripts:"
    for script in "${UNIT_TEST_SCRIPTS[@]}"; do
      log_info " • $(basename "${script}")"
    done
  fi
  # List integration tests
  if is_true "${RUN_INTEGRATION}"; then
    log_info "Running ${#INTEGRATION_TEST_SCRIPTS[@]} integration test scripts:"
    for script in "${INTEGRATION_TEST_SCRIPTS[@]}"; do
      log_info " • $(basename "${script}")"
    done
  fi
  # Run unit test scripts (with mocks)
  local failed_scripts=()
  if is_true "${RUN_UNIT}"; then
    for script in "${UNIT_TEST_SCRIPTS[@]}"; do
      if ! run_test_script "${script}" false; then
        failed_scripts+=("$(basename "${script}")")
      fi
    done
  fi
  # Run integration test scripts (without mocks)
  if is_true "${RUN_INTEGRATION}"; then
    for script in "${INTEGRATION_TEST_SCRIPTS[@]}"; do
      if ! run_test_script "${script}" true; then
        failed_scripts+=("$(basename "${script}")")
      fi
    done
  fi
  # Summarize results
  log_info "=== Test Suite Summary ==="
  log_info "Total test scripts: ${TOTAL_TESTS}"
  log_info "Passed: ${TOTAL_PASSED}"
  log_info "Failed: ${TOTAL_FAILED}"
  if [[ ${TOTAL_FAILED} -gt 0 ]]; then
    log_error "Failed test scripts: ${failed_scripts[*]}"
    exit 1
  else
    log_success "All tests passed successfully!"
    exit 0
  fi
}
# --- Entry ----------------------------------------------------------------------
main "$@"