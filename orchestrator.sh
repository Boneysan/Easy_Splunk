#!/usr/bin/env bash
# ==============================================================================
# orchestrator.sh
# Main entrypoint: parse config, validate host, detect runtime, generate compose,
# and bring the stack up with retries + health wait.
#
# Dependencies:
#   lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
#   lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
#   parse-args.sh
# ==============================================================================

# --- Strict Mode & Setup --------------------------------------------------------
set -eEuo pipefail
IFS=$'\n\t'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# --- Source Dependencies (ordered) ---------------------------------------------
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"
# shellcheck source=lib/error-handling.sh
source "${SCRIPT_DIR}/lib/error-handling.sh"

# versions: keep env data separate from helpers
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/compose-generator.sh
source "${SCRIPT_DIR}/lib/compose-generator.sh"
# shellcheck source=parse-args.sh
source "${SCRIPT_DIR}/parse-args.sh"

# --- Defaults / Tunables --------------------------------------------------------
: "${WORKDIR:=${PWD}}"
: "${COMPOSE_FILE:=${WORKDIR}/docker-compose.yml}"
: "${ENV_FILE:=${WORKDIR}/.env}"
: "${HEALTH_WAIT_SECONDS:=30}"       # simple post-up settle time
: "${SPLUNK_WAIT_SECONDS:=120}"      # additional wait for Splunk services
: "${STARTUP_DEADLINE:=300}"         # seconds; total budget for compose up retries
: "${RETRIES:=5}"                    # attempts inside with_retry
: "${RETRY_BASE_DELAY:=2}"           # seconds
: "${RETRY_MAX_DELAY:=20}"           # seconds
: "${HEALTH_CHECK_RETRIES:=10}"      # health check attempts
: "${HEALTH_CHECK_INTERVAL:=15}"     # seconds between health checks

# Ensure workdir exists; register cleanup for any temp artifacts
mkdir -p "${WORKDIR}"

# --- Enhanced Functions --------------------------------------------------------
_show_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                           SPLUNK CLUSTER ORCHESTRATOR                       ║
║                                                                              ║
║  Automated deployment and management of containerized Splunk clusters       ║
║  with monitoring, security, and enterprise-grade reliability                ║
╚══════════════════════════════════════════════════════════════════════════════╝
EOF
}

_preflight() {
  log_info "🔎 Running comprehensive preflight checks..."
  
  # System resources with Splunk-appropriate minimums
  local min_ram=4096
  local min_cores=2
  
  # Increase requirements for Splunk clusters
  if is_true "${ENABLE_SPLUNK}"; then
    min_ram=$((8192 * INDEXER_COUNT + 4096 * SEARCH_HEAD_COUNT))
    min_cores=$((2 * INDEXER_COUNT + SEARCH_HEAD_COUNT))
    log_info "Splunk cluster detected: requiring ${min_ram}MB RAM, ${min_cores} CPU cores"
  fi
  
  enforce_system_resources "${min_ram}" "${min_cores}"
  
  # Disk space validation
  validate_disk_space "${DATA_DIR}" 10
  if is_true "${ENABLE_SPLUNK}"; then
    validate_disk_space "${SPLUNK_DATA_DIR}" $((20 * INDEXER_COUNT))
  fi
  
  # Kernel parameters for production workloads
  validate_vm_max_map_count 262144 || log_warn "Consider: sysctl -w vm.max_map_count=262144"
  
  # Port availability checks
  log_info "Checking port availability..."
  validate_port_free "${APP_PORT}"
  
  if is_true "${ENABLE_SPLUNK}"; then
    validate_port_free "${SPLUNK_WEB_PORT}"
    # Check indexer ports (9997 base + instance)
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      validate_port_free $((9997 + i - 1))
    done
  fi
  
  if is_true "${ENABLE_MONITORING}"; then
    validate_port_free 9090  # Prometheus
    validate_port_free 3000  # Grafana
  fi
  
  # Container runtime validation
  validate_docker_daemon "${CONTAINER_RUNTIME}"
  
  log_success "All preflight checks passed"
}

_setup_directories() {
  log_info "🗂️ Setting up directory structure..."
  
  # Create required directories with proper permissions
  local dirs=(
    "${DATA_DIR}"
    "${WORKDIR}/config"
    "${WORKDIR}/logs"
  )
  
  if is_true "${ENABLE_SPLUNK}"; then
    dirs+=(
      "${SPLUNK_DATA_DIR}"
      "${WORKDIR}/config/splunk"
    )
  fi
  
  if is_true "${ENABLE_MONITORING}"; then
    dirs+=(
      "${WORKDIR}/config/prometheus"
      "${WORKDIR}/config/grafana-provisioning/datasources"
      "${WORKDIR}/config/grafana-provisioning/dashboards"
    )
  fi
  
  for dir in "${dirs[@]}"; do
    if [[ ! -d "$dir" ]]; then
      mkdir -p "$dir"
      log_debug "Created directory: $dir"
    fi
  done
  
  # Set appropriate permissions
  chmod 755 "${DATA_DIR}"
  if is_true "${ENABLE_SPLUNK}"; then
    chmod 755 "${SPLUNK_DATA_DIR}"
  fi
  
  log_success "Directory structure ready"
}

_generate_supporting_configs() {
  log_info "📝 Generating supporting configuration files..."
  
  # Generate .env file for compose
  generate_env_template "${ENV_FILE}"
  
  # Generate monitoring configs if enabled
  if is_true "${ENABLE_MONITORING}"; then
    _generate_prometheus_config
    _generate_grafana_config
  fi
  
  # Generate Splunk configs if enabled
  if is_true "${ENABLE_SPLUNK}"; then
    _generate_splunk_configs
  fi
}

_generate_prometheus_config() {
  local config_file="${WORKDIR}/config/prometheus.yml"
  log_info "Generating Prometheus configuration: ${config_file}"
  
  cat > "${config_file}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'app'
    static_configs:
      - targets: ['app:8080']
  
  - job_name: 'redis'
    static_configs:
      - targets: ['redis:6379']
EOF

  if is_true "${ENABLE_SPLUNK}"; then
    cat >> "${config_file}" <<EOF
  
  - job_name: 'splunk-cluster'
    static_configs:
      - targets:
$(for ((i=1; i<=INDEXER_COUNT; i++)); do echo "        - 'splunk-idx${i}:8089'"; done)
$(for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do echo "        - 'splunk-sh${i}:8089'"; done)
EOF
  fi
}

_generate_grafana_config() {
  local datasource_file="${WORKDIR}/config/grafana-provisioning/datasources/prometheus.yml"
  log_info "Generating Grafana datasource configuration: ${datasource_file}"
  
  cat > "${datasource_file}" <<EOF
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF
}

_generate_splunk_configs() {
  log_info "Generating Splunk configuration files..."
  
  # Basic server.conf for indexers
  local splunk_config_dir="${WORKDIR}/config/splunk"
  mkdir -p "${splunk_config_dir}"
  
  # This would be expanded with actual Splunk configuration
  # For now, just create a placeholder
  cat > "${splunk_config_dir}/README.md" <<EOF
# Splunk Configuration

This directory contains Splunk configuration files that will be
mounted into the containers during deployment.

Configuration files:
- server.conf: Basic server configuration
- indexes.conf: Index definitions
- inputs.conf: Data input configuration
- web.conf: Splunk Web configuration

For production deployments, customize these files according to your
organizational requirements.
EOF
}

_generate_compose() {
  log_info "🧩 Generating Docker Compose configuration..."
  
  begin_step "generate_compose"
  
  # Set environment variables for compose generation
  export COMPOSE_PROJECT_NAME
  export INDEXER_COUNT SEARCH_HEAD_COUNT
  export SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR
  
  generate_compose_file "${COMPOSE_FILE}"
  
  complete_step "generate_compose"
  log_success "Compose file generated: ${COMPOSE_FILE}"
}

_prepare_images() {
  log_info "🐳 Preparing container images..."
  
  begin_step "prepare_images"
  
  if has_capability "air-gapped"; then
    log_info "Air-gapped mode detected - assuming images are pre-loaded"
    complete_step "prepare_images"
    return 0
  fi
  
  # Pull required images with retry
  local images_to_pull=("${APP_IMAGE}" "${REDIS_IMAGE}")
  
  if is_true "${ENABLE_MONITORING}"; then
    images_to_pull+=("${PROMETHEUS_IMAGE}" "${GRAFANA_IMAGE}")
  fi
  
  if is_true "${ENABLE_SPLUNK}"; then
    images_to_pull+=("${SPLUNK_IMAGE}")
  fi
  
  log_info "Pulling ${#images_to_pull[@]} container images..."
  
  for image in "${images_to_pull[@]}"; do
    log_info "Pulling ${image}..."
    with_retry --retries 3 --base-delay 5 -- \
      "${CONTAINER_RUNTIME}" pull "${image}"
  done
  
  complete_step "prepare_images"
  log_success "All container images ready"
}

_start_stack() {
  log_info "🚀 Starting the application stack..."
  
  begin_step "start_stack"
  
  # Build compose profiles based on enabled services
  local profiles=()
  if is_true "${ENABLE_MONITORING}"; then
    profiles+=("monitoring")
  fi
  if is_true "${ENABLE_SPLUNK}"; then
    profiles+=("splunk")
  fi
  
  # Set up environment for compose
  local compose_env=()
  if [[ ${#profiles[@]} -gt 0 ]]; then
    local profile_list
    profile_list=$(IFS=,; echo "${profiles[*]}")
    compose_env=("COMPOSE_PROFILES=${profile_list}")
  fi
  
  # Check for dry run
  if is_true "${DRY_RUN}"; then
    log_warn "DRY RUN: Would execute: ${compose_env[*]} compose -f '${COMPOSE_FILE}' up -d --remove-orphans"
    complete_step "start_stack"
    return 0
  fi
  
  # Start services with retry logic
  log_info "Starting services with profiles: ${profiles[*]:-none}"
  
  deadline_retry "${STARTUP_DEADLINE}" -- \
    --retries "${RETRIES}" --base-delay "${RETRY_BASE_DELAY}" --max-delay "${RETRY_MAX_DELAY}" -- \
    env "${compose_env[@]}" compose -f "${COMPOSE_FILE}" up -d --remove-orphans
  
  complete_step "start_stack"
  log_success "Stack startup completed"
}

_wait_for_health() {
  log_info "⏳ Waiting for services to become healthy..."
  
  begin_step "health_check"
  
  # Basic settle time
  log_info "Initial settling period: ${HEALTH_WAIT_SECONDS}s"
  sleep "${HEALTH_WAIT_SECONDS}"
  
  # Extended wait for Splunk services
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "Additional Splunk startup wait: ${SPLUNK_WAIT_SECONDS}s"
    sleep "${SPLUNK_WAIT_SECONDS}"
  fi
  
  # Health check with retries
  local health_attempts=0
  while (( health_attempts < HEALTH_CHECK_RETRIES )); do
    log_info "Health check attempt $((health_attempts + 1))/${HEALTH_CHECK_RETRIES}"
    
    if compose -f "${COMPOSE_FILE}" ps --format json | jq -e '.[] | select(.Health == "unhealthy")' >/dev/null 2>&1; then
      log_warn "Some services are unhealthy, waiting ${HEALTH_CHECK_INTERVAL}s..."
      sleep "${HEALTH_CHECK_INTERVAL}"
      ((health_attempts++))
    else
      log_success "All services are healthy"
      break
    fi
  done
  
  if (( health_attempts >= HEALTH_CHECK_RETRIES )); then
    log_warn "Health check timeout reached, but continuing..."
  fi
  
  complete_step "health_check"
}

_show_status() {
  log_info "📋 Deployment Status:"
  
  # Container status
  compose -f "${COMPOSE_FILE}" ps || true
  
  # Service endpoints
  log_info ""
  log_info "🌐 Service Endpoints:"
  log_info "• Application: http://localhost:${APP_PORT}"
  
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "• Splunk Web: http://localhost:${SPLUNK_WEB_PORT}"
    log_info "• Splunk Credentials: admin / ${SPLUNK_PASSWORD:0:3}***"
  fi
  
  if is_true "${ENABLE_MONITORING}"; then
    log_info "• Prometheus: http://localhost:9090"
    log_info "• Grafana: http://localhost:3000 (admin/admin)"
  fi
  
  # Useful commands
  log_info ""
  log_info "📚 Useful Commands:"
  log_info "• View logs: compose -f '${COMPOSE_FILE}' logs -f [service]"
  log_info "• Stop stack: compose -f '${COMPOSE_FILE}' down"
  log_info "• Restart service: compose -f '${COMPOSE_FILE}' restart [service]"
  log_info "• Scale indexers: compose -f '${COMPOSE_FILE}' up -d --scale splunk-idx1=N"
}

_cleanup_on_failure() {
  log_warn "Deployment failed - cleaning up partial deployment..."
  
  if [[ -f "${COMPOSE_FILE}" ]]; then
    compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi
  
  # List incomplete steps for troubleshooting
  local incomplete_steps
  incomplete_steps=$(list_incomplete_steps)
  if [[ -n "$incomplete_steps" ]]; then
    log_info "Incomplete deployment steps: $incomplete_steps"
    log_info "Use these to debug deployment issues"
  fi
}

_main() {
  _show_banner
  log_info "🚀 Starting Cluster Orchestrator ($(date))..."
  
  # Register cleanup on failure
  register_cleanup "_cleanup_on_failure"
  
  # 1) Parse CLI/config; persist normalized config beside compose for traceability
  local effective_cfg="${WORKDIR}/config.effective"
  parse_arguments --write-effective "${effective_cfg}" "$@"
  
  # 2) Comprehensive preflight validation
  _preflight
  
  # 3) Detect container runtime + compose implementation
  detect_container_runtime
  enhanced_runtime_summary
  
  # 4) Setup directory structure and supporting configs
  _setup_directories
  _generate_supporting_configs
  
  # 5) Prepare container images
  _prepare_images
  
  # 6) Generate compose file atomically
  _generate_compose
  
  # 7) Start the stack with resilience
  _start_stack
  
  # 8) Wait for services to be healthy
  _wait_for_health
  
  # 9) Show final status and next steps
  _show_status
  
  # Unregister cleanup since we succeeded
  unregister_cleanup "_cleanup_on_failure"
  
  log_success "✅ Deployment completed successfully!"
  
  if is_true "${DRY_RUN}"; then
    log_info "This was a dry run - no actual deployment was performed"
  fi
}

# --- Entry ----------------------------------------------------------------------
_main "$@"