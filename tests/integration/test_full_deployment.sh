#!/usr/bin/env bash
#
# ==============================================================================
# tests/integration/test_full_deployment.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# An end-to-end integration test that simulates a full, clean deployment of
# the application stack. It is intended to be run as part of the release
# validation process.
#
# Features:
#   - End-to-end Testing: Runs orchestrator.sh, health_check.sh, and stop_cluster.sh
#     in sequence to validate the entire user workflow.
#   - Full Cleanup: Ensures a clean environment by tearing down any existing
#     deployments and artifacts before starting.
#   - Performance Benchmarking: Includes a simple time measurement for the
#     main deployment step.
#
# Dependencies: All user-facing component scripts
# Required by:  Release validation
#
# ==============================================================================

# --- Strict Mode & Setup ---
# Don't use 'set -e' in a test script, as we want to control execution and report failures.
set -uo pipefail

# --- Source Dependencies ---
# This test is run from the project root, so paths are relative from there.
source "./lib/core.sh"
source "./lib/error-handling.sh"

# --- Simple Test Framework ---
TEST_COUNT=0
FAIL_COUNT=0

# A simple assertion function
assert_success() {
    local description="$1"
    shift
    local command_to_run=("$@")
    
    TEST_COUNT=$((TEST_COUNT + 1))
    log_info "TEST: ${description}"
    
    # Run command, capturing output and exit code
    local output
    output=$("${command_to_run[@]}" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        log_success "PASS: ${description}"
    else
        log_error "FAIL: ${description}"
        log_error "  -> Exit Code: ${exit_code}"
        log_error "  -> Output:\n${output}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# --- Test Environment Setup & Teardown ---

# Ensures the environment is clean before starting the test.
setup() {
    log_info "--- Preparing clean test environment ---"
    # Stop and fully remove any pre-existing cluster
    if [[ -f ./stop_cluster.sh ]]; then
        # Pipe 'yes' to handle the confirmation prompt for volume deletion
        yes | ./stop_cluster.sh --with-volumes &>/dev/null || true
    fi
    
    # Remove generated files and directories
    rm -f docker-compose.yml
    rm -rf ./config
    rm -rf ./management-scripts
    rm -f ./*.bak
    log_success "Environment is clean."
}

# Ensures the cluster is stopped after the test, even on failure.
teardown() {
    log_info "--- Tearing down test environment ---"
    if [[ -f ./stop_cluster.sh ]]; then
        ./stop_cluster.sh &>/dev/null || true
    fi
    log_success "Teardown complete."
}

# --- Main Test Execution ---

run_deployment_test() {
    log_info "--- Step 1: Testing Credential & Config Generation ---"
    # Pipe 'yes' to auto-confirm prompts in the scripts
    assert_success "generate-credentials.sh should run successfully" \
        yes | ./generate-credentials.sh
    assert_success "generate-monitoring-config.sh should run successfully" \
        yes | ./generate-monitoring-config.sh
    
    log_info "\n--- Step 2: Testing Main Deployment Orchestration ---"
    log_info "Timing the main orchestrator script..."
    # The 'time' command outputs to stderr, which is fine here.
    local start_time
    start_time=$(date +%s)
    # Run the orchestrator with monitoring enabled for a full test
    ./orchestrator.sh --with-monitoring
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    log_success "Orchestrator finished in ${duration} seconds."
    
    log_info "\n--- Step 3: Verifying Cluster Health ---"
    # Allow a moment for services to fully stabilize after orchestrator exits
    log_info "Waiting 15 seconds for services to stabilize..."
    sleep 15
    assert_success "health_check.sh should report all services are healthy" \
        ./health_check.sh

    log_info "\n--- Step 4: Testing Basic Application Endpoint ---"
    assert_success "Application should be responding on its port" \
        curl --fail --silent http://localhost:8080

    log_info "\n--- Step 5: Testing Cluster Shutdown ---"
    assert_success "stop_cluster.sh should shut down the cluster gracefully" \
        ./stop_cluster.sh

    log_info "\n--- Step 6: Verifying Teardown ---"
    # After stopping, there should be no containers left.
    local running_containers
    running_containers=$(docker ps -a -q)
    if is_empty "$running_containers"; then
        log_success "PASS: All containers were successfully removed."
    else
        log_error "FAIL: Lingering containers found after shutdown."
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}


main() {
    # Ensure teardown runs even if the script is interrupted
    trap teardown EXIT INT TERM

    setup
    run_deployment_test

    # --- Report Final Results ---
    log_info "\n--- Integration Test Summary ---"
    if (( FAIL_COUNT == 0 )); then
        log_success "✅ All ${TEST_COUNT} integration tests passed!"
        exit 0
    else
        log_error "❌ ${FAIL_COUNT} of ${TEST_COUNT} integration tests failed."
        exit 1
    fi
}

main