```bash
#!/usr/bin/env bash
# ==============================================================================
# run_all_tests.sh
# Master script to run all unit tests for the Splunk cluster orchestrator project.
#
# Dependencies: lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#               lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#               lib/security.sh, lib/monitoring.sh, lib/parse-args.sh, lib/air-gapped.sh,
#               lib/universal-forwarder.sh, lib/platform-helpers.sh, orchestrator.sh,
#               generate-credentials.sh, generate-monitoring-config.sh, create-airgapped.sh,
#               airgapped-quickstart.sh, generate-selinux-helpers.sh, podman-docker-setup.sh,
#               start_cluster.sh, stop_cluster.sh, health_check.sh, backup_cluster.sh,
#               restore_cluster.sh, generate-management-scripts.sh, tests/unit/test_*.sh
# Version: 1.0.11
# ==============================================================================
# --- Strict Mode & Setup --------------------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
# --- Source Core Dependencies ---------------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"
# --- Defaults / Flags -----------------------------------------------------------
VERBOSE=false
TEST_FILTER=""
# --- CLI Parsing ----------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    --filter)
      TEST_FILTER="${2:?filter required}"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $(basename "$0") [OPTIONS]
Runs all unit tests for the Splunk cluster orchestrator project.
Options:
  -v, --verbose  Enable verbose output (sets DEBUG=true)
  --filter REGEX Only run test scripts matching REGEX
  -h, --help     Show this help and exit
Examples:
  $(basename "$0")                 # Run all tests
  $(basename "$0") --verbose       # Run all tests with verbose output
  $(basename "$0") --filter parse  # Run only tests matching 'parse'
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
TEST_SCRIPTS=()
while IFS= read -r script; do
  TEST_SCRIPTS+=("$script")
done < <(find "${SCRIPT_DIR}/tests/unit" -type f -name "test_*.sh" | sort)
# Filter test scripts if specified
if [[ -n "${TEST_FILTER}" ]]; then
  filtered_scripts=()
  for script in "${TEST_SCRIPTS[@]}"; do
    if [[ "$(basename "${script}")" =~ ${TEST_FILTER} ]]; then
      filtered_scripts+=("${script}")
    fi
  done
  TEST_SCRIPTS=("${filtered_scripts[@]}")
fi
# Global test counters
TOTAL_TESTS=0
TOTAL_PASSED=0
TOTAL_FAILED=0
# --- Helpers --------------------------------------------------------------------
run_test_script() {
  local script="$1"
  local script_name
  script_name=$(basename "${script}")
  log_info "Running test script: ${script_name} ($(date)) at ${script}"
  begin_step "test_${script_name}"
  # Run in a subshell to avoid state pollution
  (
    # Source dependencies
    for dep in core.sh error-handling.sh versions.sh validation.sh runtime-detection.sh compose-generator.sh security.sh monitoring.sh parse-args.sh air-gapped.sh universal-forwarder.sh platform-helpers.sh orchestrator.sh generate-credentials.sh generate-monitoring-config.sh create-airgapped.sh airgapped-quickstart.sh generate-selinux-helpers.sh podman-docker-setup.sh start_cluster.sh stop_cluster.sh health_check.sh backup_cluster.sh restore_cluster.sh generate-management-scripts.sh; do
      # shellcheck source=/dev/null
      source "${SCRIPT_DIR}/lib/${dep}"
    done
    if [[ -f "${SCRIPT_DIR}/versions.env" ]]; then
      # shellcheck source=/dev/null
      source "${SCRIPT_DIR}/versions.env"
    else
      log_error "versions.env not found"
      exit 1
    fi
    # Mock container runtime to avoid actual system changes
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
    # Mock system commands for validation.sh, security.sh, monitoring.sh, air-gapped.sh, universal-forwarder.sh, platform-helpers.sh, start_cluster.sh, stop_cluster.sh, health_check.sh, backup_cluster.sh, restore_cluster.sh, generate-management-scripts.sh
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
║ Runs all unit tests for the Splunk cluster orchestrator project               ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
  }
  _show_banner
  log_info "🚀 Starting test suite ($(date))..."
  # Validate test scripts exist
  if [[ ${#TEST_SCRIPTS[@]} -eq 0 ]]; then
    log_error "No test scripts found in ${SCRIPT_DIR}/tests/unit"
    exit 1
  fi
  log_info "Running ${#TEST_SCRIPTS[@]} test scripts:"
  for script in "${TEST_SCRIPTS[@]}"; do
    log_info " • $(basename "${script}")"
  done
  # Run each test script
  local failed_scripts=()
  for script in "${TEST_SCRIPTS[@]}"; do
    if ! run_test_script "${script}"; then
      failed_scripts+=("$(basename "${script}")")
    fi
  done
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
```