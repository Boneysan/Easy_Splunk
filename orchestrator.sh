```bash
#!/usr/bin/env bash
# ==============================================================================
# orchestrator.sh
# Main entrypoint: parse config, validate host, detect runtime, generate compose,
# and bring the stack up with retries + health wait.
#
# Dependencies:
# lib/core.sh, lib/error-handling.sh, versions.env, lib/versions.sh,
# lib/validation.sh, lib/runtime-detection.sh, lib/compose-generator.sh,
# lib/security.sh, lib/monitoring.sh, parse-args.sh
# Version: 1.0.2
#
# Usage Examples:
#   ./orchestrator.sh --with-splunk --indexers 3 --splunk-password secret
#   ./orchestrator.sh --config production.env --dry-run
#   ./orchestrator.sh --interactive --with-monitoring
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
# shellcheck source=lib/security.sh
source "${SCRIPT_DIR}/lib/security.sh"
# shellcheck source=lib/monitoring.sh
source "${SCRIPT_DIR}/lib/monitoring.sh"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"
# shellcheck source=lib/versions.sh
source "${SCRIPT_DIR}/lib/versions.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/lib/validation.sh"
# shellcheck source=lib/runtime-detection.sh
source "${SCRIPT_DIR}/lib/runtime-detection.sh"
# shellcheck source=lib/compose-generator.sh
source "${SCRIPT_DIR}/lib/compose-generator.sh"
# shellcheck source=parse-args.sh
source "${SCRIPT_DIR}/parse-args.sh"

# --- Dependency Version Checks --------------------------------------------------
if [[ "${CORE_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "orchestrator.sh requires core.sh version >= 1.0.0"
fi
if [[ "${ERROR_HANDLING_VERSION:-0.0.0}" < "1.0.4" ]]; then
  die "${E_GENERAL}" "orchestrator.sh requires error-handling.sh version >= 1.0.4"
fi
if [[ "${SECURITY_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "orchestrator.sh requires security.sh version >= 1.0.0"
fi
if [[ "${MONITORING_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "orchestrator.sh requires monitoring.sh version >= 1.0.0"
fi
verify_versions_env || die "${E_INVALID_INPUT}" "versions.env contains invalid values"

# --- Defaults / Tunables --------------------------------------------------------
: "${WORKDIR:=${PWD}}"
: "${COMPOSE_FILE:=${WORKDIR}/docker-compose.yml}"
: "${ENV_FILE:=${WORKDIR}/.env}"
: "${HEALTH_WAIT_SECONDS:=30}"        # simple post-up settle time
: "${SPLUNK_WAIT_SECONDS:=120}"       # additional wait for Splunk services
: "${STARTUP_DEADLINE:=300}"          # seconds; total budget for compose up retries
: "${RETRIES:=5}"                     # attempts inside with_retry
: "${RETRY_BASE_DELAY:=2}"            # seconds
: "${RETRY_MAX_DELAY:=20}"            # seconds
: "${HEALTH_CHECK_RETRIES:=10}"       # health check attempts
: "${HEALTH_CHECK_INTERVAL:=15}"      # seconds between health checks

# Ensure workdir exists; register cleanup for any temp artifacts
mkdir -p "${WORKDIR}"

# Whether JSON ps is supported (set during detection)
COMPOSE_PS_JSON_SUPPORTED=0

# --- Enhanced Functions --------------------------------------------------------
_show_banner() {
  cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║ SPLUNK CLUSTER ORCHESTRATOR                                                  ║
║                                                                              ║
║ Automated deployment and management of containerized Splunk clusters          ║
║ with monitoring, security, and enterprise-grade reliability                   ║
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
  enforce_vm_max_map_count 262144
  # Port availability checks
  log_info "Checking port availability..."
  if ! validate_port_free "${APP_PORT}"; then
    log_warn "Try a different port, e.g., $((APP_PORT + 1))"
    die "${E_INVALID_INPUT}" "Port ${APP_PORT} is in use"
  fi
  if is_true "${ENABLE_SPLUNK}"; then
    if ! validate_port_free "${SPLUNK_WEB_PORT}"; then
      log_warn "Try a different Splunk web port, e.g., $((SPLUNK_WEB_PORT + 1))"
      die "${E_INVALID_INPUT}" "Splunk web port ${SPLUNK_WEB_PORT} is in use"
    fi
    # Check indexer ports (9997 base + instance)
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      local port=$((9997 + i - 1))
      if ! validate_port_free "${port}"; then
        log_warn "Try a different indexer port, e.g., $((port + 1))"
        die "${E_INVALID_INPUT}" "Indexer port ${port} is in use"
      fi
    done
  fi
  if is_true "${ENABLE_MONITORING}"; then
    if ! validate_port_free 9090; then
      log_warn "Try a different Prometheus port, e.g., 9091"
      die "${E_INVALID_INPUT}" "Prometheus port 9090 is in use"
    fi
    if ! validate_port_free 3000; then
      log_warn "Try a different Grafana port, e.g., 3001"
      die "${E_INVALID_INPUT}" "Grafana port 3000 is in use"
    fi
  fi
  # Container runtime validation
  validate_docker_daemon "${CONTAINER_RUNTIME}"
  # Security audit
  audit_security_configuration "${WORKDIR}/security-audit.txt"
  log_success "All preflight checks passed"
}

_setup_directories() {
  log_info "🗂️ Setting up directory structure..."
  # Create required directories with proper permissions
  local dirs=(
    "${DATA_DIR}"
    "${WORKDIR}/config"
    "${WORKDIR}/logs"
    "${WORKDIR}/secrets"
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
  chmod 700 "${WORKDIR}/secrets"
  log_success "Directory structure ready"
}

_generate_secrets() {
  if is_true "${ENABLE_SECRETS}" && has_capability "secrets"; then
    log_info "📝 Generating secrets files..."
    setup_splunk_secrets "${SPLUNK_PASSWORD}" "${SPLUNK_SECRET}" "${WORKDIR}/secrets"
    if is_true "${ENABLE_MONITORING}"; then
      write_secret_file "${WORKDIR}/secrets/grafana_admin_password.txt" "${GRAFANA_ADMIN_PASSWORD:-admin}" "Grafana admin password"
    fi
    log_success "Secrets files generated in ${WORKDIR}/secrets"
  fi
}

_generate_supporting_configs() {
  log_info "📝 Generating supporting configuration files..."
  # Generate .env file for compose
  generate_env_template "${ENV_FILE}"
  # Generate secrets if enabled
  _generate_secrets
  # Generate monitoring configs if enabled
  if is_true "${ENABLE_MONITORING}"; then
    SPLUNK_INDEXER_COUNT="${INDEXER_COUNT}" SPLUNK_SEARCH_HEAD_COUNT="${SEARCH_HEAD_COUNT}" generate_monitoring_config
  fi
  # Generate Splunk configs if enabled
  if is_true "${ENABLE_SPLUNK}"; then
    _generate_splunk_configs
  fi
}

_generate_splunk_configs() {
  log_info "Generating Splunk configuration files..."
  local splunk_config_dir="${WORKDIR}/config/splunk"
  mkdir -p "${splunk_config_dir}"
  cat > "${splunk_config_dir}/server.conf" <<EOF
[general]
serverName = \${HOSTNAME}
[sslConfig]
enableSplunkdSSL = true
EOF
  cat > "${splunk_config_dir}/inputs.conf" <<EOF
[default]
host = \${HOSTNAME}
EOF
  cat > "${splunk_config_dir}/README.md" <<'EOF'
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
  # Generate SSL certificates for Splunk
  if is_true "${ENABLE_SPLUNK}"; then
    generate_splunk_ssl_cert "splunk-cm" "${WORKDIR}/secrets/splunk"
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      generate_splunk_ssl_cert "splunk-idx${i}" "${WORKDIR}/secrets/splunk"
    done
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      generate_splunk_ssl_cert "splunk-sh${i}" "${WORKDIR}/secrets/splunk"
    done
  fi
}

_generate_compose() {
  log_info "🧩 Generating Docker Compose configuration..."
  begin_step "generate_compose"
  export COMPOSE_PROJECT_NAME INDEXER_COUNT SEARCH_HEAD_COUNT SPLUNK_REPLICATION_FACTOR SPLUNK_SEARCH_FACTOR
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
    deadline_run 60 -- with_retry --retries 3 --base-delay 5 -- \
      "${CONTAINER_RUNTIME}" pull "${image}"
  done
  complete_step "prepare_images"
  log_success "All container images ready"
}

_detect_ps_json_support() {
  if compose -f "${COMPOSE_FILE}" ps --format json >/dev/null 2>&1; then
    COMPOSE_PS_JSON_SUPPORTED=1
  else
    COMPOSE_PS_JSON_SUPPORTED=0
  fi
  log_debug "compose ps --format json supported: ${COMPOSE_PS_JSON_SUPPORTED}"
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
  if ! have_cmd jq || (( COMPOSE_PS_JSON_SUPPORTED == 0 )); then
    log_info "Performing simple health wait (jq or JSON unsupported)"
    sleep $((HEALTH_CHECK_RETRIES * HEALTH_CHECK_INTERVAL))
    complete_step "health_check"
    return 0
  fi
  local health_attempts=0
  while (( health_attempts < HEALTH_CHECK_RETRIES )); do
    log_info "Health check attempt $((health_attempts + 1))/${HEALTH_CHECK_RETRIES}"
    if compose -f "${COMPOSE_FILE}" ps --format json | jq -e '.[] | select(.Health == "unhealthy")' >/dev/null; then
      log_warn "Some services are unhealthy, waiting ${HEALTH_CHECK_INTERVAL}s..."
      sleep "${HEALTH_CHECK_INTERVAL}"
      ((health_attempts++))
      continue
    fi
    if compose -f "${COMPOSE_FILE}" ps --format json | jq -e 'map(select(.Health != null)) | length > 0 and (all(.[]; .Health == "healthy"))' >/dev/null; then
      log_success "All services report healthy"
      break
    fi
    log_info "Services not reporting health yet; waiting ${HEALTH_CHECK_INTERVAL}s..."
    sleep "${HEALTH_CHECK_INTERVAL}"
    ((health_attempts++))
  done
  if (( health_attempts >= HEALTH_CHECK_RETRIES )); then
    log_warn "Health check timeout reached, but continuing..."
  fi
  complete_step "health_check"
}

_show_status() {
  log_info "📋 Deployment Status:"
  compose -f "${COMPOSE_FILE}" ps || true
  log_info ""
  log_info "🌐 Service Endpoints:"
  log_info "• Application: http://localhost:${APP_PORT}"
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "• Splunk Web: http://localhost:${SPLUNK_WEB_PORT}"
    log_info "• Splunk Credentials: admin / ${SPLUNK_PASSWORD:0:3}***"
  fi
  if is_true "${ENABLE_MONITORING}"; then
    log_info "• Prometheus: http://localhost:9090"
    log_info "• Grafana: http://localhost:3000 (admin/${GRAFANA_ADMIN_PASSWORD:-admin})"
  fi
  log_info ""
  log_info "📚 Useful Commands:"
  log_info "• View logs: compose -f '${COMPOSE_FILE}' logs -f [service]"
  log_info "• Stop stack: compose -f '${COMPOSE_FILE}' down"
  log_info "• Restart service: compose -f '${COMPOSE_FILE}' restart [service]"
  log_info "• Scale services: compose -f '${COMPOSE_FILE}' up -d --scale <service>=N"
}

_cleanup_on_failure() {
  log_warn "Deployment failed - cleaning up partial deployment..."
  if [[ -f "${COMPOSE_FILE}" ]]; then
    compose -f "${COMPOSE_FILE}" down --remove-orphans 2>/dev/null || true
  fi
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
  # 1) Parse CLI/config; persist normalized config
  local effective_cfg="${WORKDIR}/config.effective"
  parse_arguments --write-effective "${effective_cfg}" "$@"
  # 2) Detect container runtime + compose implementation
  detect_container_runtime
  enhanced_runtime_summary
  # 3) Determine health-check support
  _detect_ps_json_support
  # 4) Comprehensive preflight validation
  _preflight
  # 5) Setup directory structure and supporting configs
  _setup_directories
  _generate_supporting_configs
  # 6) Prepare container images
  _prepare_images
  # 7) Generate compose file atomically
  _generate_compose
  # 8) Start the stack with resilience
  _start_stack
  # 9) Wait for services to be healthy
  _wait_for_health
  # 10) Show final status and next steps
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
```