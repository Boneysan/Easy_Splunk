#!/usr/bin/env bash
#
# ==============================================================================
# health_check.sh
# ------------------------------------------------------------------------------
# ⭐⭐⭐
#
# Runs a comprehensive diagnostic check on the running application cluster.
# It provides a detailed report on container status, resource usage, recent
# logs, and monitoring system health.
#
# Features:
#   - Comprehensive Diagnostics: Checks container status, health, and restart counts.
#   - Performance Monitoring: Displays a snapshot of CPU and memory usage.
#   - Automated Troubleshooting: Scans recent logs for error keywords.
#   - Monitoring Integration: Queries the live Prometheus API to check target health.
#
# Dependencies: core.sh
# Required by:  Operations, Administrators
#
# ==============================================================================

# --- Strict Mode & Setup ---
set -euo pipefail

# --- Source Dependencies ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/lib/core.sh"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/runtime-detection.sh"

# --- Configuration ---
readonly COMPOSE_FILE="docker-compose.yml"
# Services to check in detail. Assumes monitoring is enabled.
readonly SERVICES_TO_CHECK=("app" "redis" "prometheus" "grafana")
# A flag to track the overall health of the system.
OVERALL_HEALTHY="true"

# --- Main Health Check Function ---

main() {
    log_info "🚀 Running Comprehensive Health Check..."

    # 1. Pre-flight Checks
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        die "$E_MISSING_DEP" "Compose file '${COMPOSE_FILE}' not found. Is the cluster deployed?"
    fi
    detect_container_runtime
    read -r -a COMPOSE_COMMAND_ARRAY <<< "$COMPOSE_COMMAND"

    # --- Section 1: Container Status & Health ---
    log_info "\n🔎 === Container Status & Health ==="
    for service in "${SERVICES_TO_CHECK[@]}"; do
        local container_id
        container_id=$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" ps -q "$service" 2>/dev/null || true)
        
        if is_empty "$container_id"; then
            log_error "  ❌ ${service}: NOT FOUND. The container does not exist."
            OVERALL_HEALTHY="false"
            continue
        fi
        
        # Get all info in one go to reduce 'inspect' calls
        local inspect_json
        inspect_json=$("${CONTAINER_RUNTIME}" inspect "$container_id")
        local status restarts health
        status=$(echo "$inspect_json" | grep '"Status":' | head -n 1 | sed 's/.*"Status": "\(.*\)",.*/\1/')
        restarts=$(echo "$inspect_json" | grep '"RestartCount":' | sed 's/.*"RestartCount": \(.*\),.*/\1/')
        health=$(echo "$inspect_json" | grep '"Health"' -A 3 | grep '"Status":' | sed 's/.*"Status": "\(.*\)",.*/\1/')

        local report="[Status: ${status}] [Restarts: ${restarts}] [Health: ${health:-N/A}]"
        
        if [[ "$status" == "running" && ("$health" == "healthy" || -z "$health") ]]; then
            log_success "  ✔️ ${service}: HEALTHY. ${report}"
            if (( restarts > 3 )); then
                log_warn "    -> Note: This service has restarted ${restarts} times."
            fi
        else
            log_error "  ❌ ${service}: UNHEALTHY. ${report}"
            OVERALL_HEALTHY="false"
        fi
    done

    # --- Section 2: Resource Usage ---
    log_info "\n📊 === Container Resource Usage (Snapshot) ==="
    "${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" stats --no-stream

    # --- Section 3: Recent Error Logs ---
    log_info "\n📜 === Scanning Logs (Last 10 Minutes) ==="
    for service in "${SERVICES_TO_CHECK[@]}"; do
        local errors
        errors=$("${COMPOSE_COMMAND_ARRAY[@]}" -f "${COMPOSE_FILE}" logs --since 10m "$service" 2>&1 | grep -iE 'error|exception|fatal|failed' || true)
        if is_empty "$errors"; then
            log_success "  ✔️ ${service}: No recent errors found in logs."
        else
            log_warn "  ⚠️ ${service}: Found potential errors in recent logs:"
            # Indent the errors for readability
            echo "$errors" | sed 's/^/    | /'
            # This is a warning, not a failure, but worth noting.
        fi
    done

    # --- Section 4: Prometheus Monitoring Status ---
    log_info "\n📈 === Prometheus Target Health ==="
    if ! curl -sf http://localhost:9090/api/v1/targets > /tmp/targets.json; then
        log_error "  ❌ Could not connect to Prometheus API at http://localhost:9090."
        OVERALL_HEALTHY="false"
    else
        # Simple check without jq: count total targets and 'up' targets
        local total_targets
        local up_targets
        total_targets=$(grep -o '"health":"' /tmp/targets.json | wc -l)
        up_targets=$(grep -o '"health":"up"' /tmp/targets.json | wc -l)

        if (( total_targets > 0 && total_targets == up_targets )); then
            log_success "  ✔️ All ${up_targets}/${total_targets} Prometheus targets are healthy."
        else
            log_error "  ❌ Only ${up_targets}/${total_targets} Prometheus targets are healthy."
            OVERALL_HEALTHY="false"
        fi
        rm /tmp/targets.json
    fi
    
    # --- Final Summary ---
    log_info "\n🏁 === Health Check Summary ==="
    if is_true "$OVERALL_HEALTHY"; then
        log_success "✅ Overall system health is GOOD."
        exit 0
    else
        log_error "❌ One or more critical health checks failed."
        exit 1
    fi
}

# --- Script Execution ---
main "$@"  