#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# lib/compose-generator.sh
# Compose file generator (modular, atomic, profile-aware)
#
# Dependencies: lib/core.sh, lib/validation.sh, lib/error-handling.sh,
#               lib/runtime-detection.sh, versions.env
# Required by: orchestrator.sh
# Version: 1.0.0
#
# Usage Examples:
#   generate_compose_file docker-compose.yml
#   generate_env_template .env
#   ENABLE_SPLUNK=true generate_compose_file splunk-compose.yml
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# SELinux helper: add :Z to bind mounts if Docker+SELinux enforcing
add_selinux_flag_if_needed() {
  local mount="$1"
  # Only add :Z for Docker with SELinux enforcing
  if [[ -f "${SCRIPT_DIR}/selinux-preflight.sh" ]]; then
    source "${SCRIPT_DIR}/selinux-preflight.sh"
    if is_selinux_enforcing && [[ "$(detect_container_runtime)" == "docker" ]]; then
      # Only add if not already present
      if [[ "$mount" =~ ^\./.*:.* && ! "$mount" =~ :[Zz]($|,) ]]; then
        # If there is a :ro or :rw, insert before it
        if [[ "$mount" =~ :(ro|rw)$ ]]; then
          echo "${mount}:Z"
        else
          echo "${mount}:Z"
        fi
        return
      fi
    fi
  fi
  echo "$mount"
}

# Load standardized error handling first
source "${SCRIPT_DIR}/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# ---- Dependency guard ----------------------------------------------------------
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: core libs must be sourced before lib/compose-generator.sh" >&2
  exit 1
fi
if [[ "${CORE_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "compose-generator.sh requires core.sh version >= 1.0.0"
fi
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${LIB_DIR}/error-handling.sh" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_DIR}/error-handling.sh"
fi
if [[ -f "${LIB_DIR}/compose-validation.sh" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_DIR}/compose-validation.sh"
fi
if ! command -v log_info >/dev/null 2>&1; then
  echo "FATAL: core libs must be sourced before lib/compose-generator.sh" >&2
  exit 1
fi
if [[ "${CORE_VERSION:-0.0.0}" < "1.0.0" ]]; then
  die "${E_GENERAL}" "compose-generator.sh requires core.sh version >= 1.0.0"
fi
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${LIB_DIR}/error-handling.sh" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_DIR}/error-handling.sh"
fi
# Load compose validation library for metadata functions
if [[ -f "${LIB_DIR}/compose-validation.sh" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_DIR}/compose-validation.sh"
fi

# Load image validation library
if [[ -f "${LIB_DIR}/image-validator.sh" ]]; then
  # shellcheck source=/dev/null
  source "${LIB_DIR}/image-validator.sh"
fi

# Fallback validate_rf_sf function for validation library compatibility
if ! type validate_rf_sf &>/dev/null; then
  validate_rf_sf() {
    local rf="$1"
    local sf="$2"
    local indexer_count="$3"
    
    # Basic validation - replication factor should not exceed indexer count
    if [[ "$rf" -gt "$indexer_count" ]]; then
      log_message WARNING "Replication factor ($rf) exceeds indexer count ($indexer_count)"
      return 1
    fi
    
    # Search factor should not exceed indexer count
    if [[ "$sf" -gt "$indexer_count" ]]; then
      log_message WARNING "Search factor ($sf) exceeds indexer count ($indexer_count)"
      return 1
    fi
    
    return 0
  }
fi
# Load versions.env from repo root
if [[ -f "${LIB_DIR}/../versions.env" ]]; then
  # shellcheck source=/dev/null
  # Normalize potential CRLF line endings when sourcing
  source <(sed 's/\r$//' "${LIB_DIR}/../versions.env")
else
  die "${E_INVALID_INPUT}" "versions.env required"
fi

# Source the secret helper if available
readonly SECRET_HELPER="${LIB_DIR}/secret-helper.sh"
if [[ ! -x "$SECRET_HELPER" ]]; then
    # Use fallback logging if log_warning not available
    if type log_warning &>/dev/null; then
        log_warning "secret-helper.sh not found or not executable, secrets may use defaults"
    else
        echo "WARNING: secret-helper.sh not found or not executable, secrets may use defaults" >&2
    fi
fi

# Configuration defaults with environment override support
: "${SECRETS_DIR:=./secrets}"
: "${ENABLE_MONITORING:=false}"
: "${ENABLE_HEALTHCHECKS:=true}"
: "${ENABLE_SPLUNK:=true}"  # Default to true for Easy_Splunk toolkit
: "${ENABLE_SECRETS:=false}"

# Load credentials from secrets manager with fallbacks
if [[ -x "$SECRET_HELPER" ]]; then
    SPLUNK_PASSWORD=$("$SECRET_HELPER" get_secret splunk "splunk_admin_password" \
        "${SECRETS_DIR}/splunk_admin_password" "changeme123" "Splunk admin password") || SPLUNK_PASSWORD="changeme123"
    SPLUNK_SECRET=$("$SECRET_HELPER" get_secret splunk "splunk_secret" \
        "${SECRETS_DIR}/splunk_secret" "changeme-secret-key" "Splunk secret key") || SPLUNK_SECRET="changeme-secret-key"
    GRAFANA_ADMIN_PASSWORD=$("$SECRET_HELPER" get_secret grafana "admin_password" \
        "${SECRETS_DIR}/grafana_admin_password" "admin123" "Grafana admin password") || GRAFANA_ADMIN_PASSWORD="admin123"
else
    : "${SPLUNK_PASSWORD:=changeme123}"  # WARNING: These are not secure defaults!
    : "${SPLUNK_SECRET:=changeme-secret-key}"
    : "${GRAFANA_ADMIN_PASSWORD:=admin123}"
fi

: "${SPLUNK_CLUSTER_MODE:=single}"  # single|cluster
: "${SPLUNK_REPLICATION_FACTOR:=1}"
: "${SPLUNK_SEARCH_FACTOR:=1}"
: "${INDEXER_COUNT:=1}"
: "${SEARCH_HEAD_COUNT:=1}"

# Optional capability flags from runtime-detection (safe defaults)
: "${COMPOSE_SUPPORTS_SECRETS:=0}"
: "${COMPOSE_SUPPORTS_HEALTHCHECK:=1}"
: "${COMPOSE_SUPPORTS_PROFILES:=1}"

# ==============================================================================
# YAML generators (each echoes a block)
# ==============================================================================

_generate_header() {
  cat <<EOF
# ------------------------------------------------------------------------------
# Auto-generated by lib/compose-generator.sh
# Generated on: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Runtime: ${CONTAINER_RUNTIME:-unknown}
# Compose: ${COMPOSE_IMPL:-unknown}
# Do not edit this file manually; it will be overwritten.
# ------------------------------------------------------------------------------
# Compose Specification (https://compose-spec.io/)
EOF
}

_generate_app_service() {
  cat <<'EOF'
  # Main application service
  app:
    image: "${APP_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_app"
    restart: unless-stopped
    ports:
      - "${APP_PORT:-8080}:8080"
    environment:
      APP_MODE: "production"
      REDIS_HOST: "redis"
      LOG_LEVEL: "${LOG_LEVEL:-info}"
    networks:
      - app-net
    volumes:
      - app-data:/app/data
      - app-logs:/app/logs
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
      interval: 15s
      timeout: 3s
      retries: 8
      start_period: 10s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${APP_CPU_LIMIT:-1.5}'
          memory: '${APP_MEM_LIMIT:-2G}'
        reservations:
          cpus: '${APP_CPU_RESERVE:-0.5}'
          memory: '${APP_MEM_RESERVE:-512M}'
    depends_on:
      redis:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

_generate_redis_service() {
  cat <<'EOF'
  # Redis caching service
  redis:
    image: "${REDIS_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_redis"
    restart: unless-stopped
    command: ["redis-server", "--save", "60", "1", "--loglevel", "warning", "--maxmemory", "256mb", "--maxmemory-policy", "allkeys-lru"]
    networks:
      - app-net
    volumes:
      - redis-data:/data
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 15s
      timeout: 3s
      retries: 10
      start_period: 5s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${REDIS_CPU_LIMIT:-0.5}'
          memory: '${REDIS_MEM_LIMIT:-512M}'
        reservations:
          cpus: '${REDIS_CPU_RESERVE:-0.1}'
          memory: '${REDIS_MEM_RESERVE:-128M}'
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "3"
EOF
}

_generate_splunk_indexer_service() {
  local instance_num="${1:-1}"
  local hostname="splunk-idx${instance_num}"

  cat <<EOF
  # Splunk Indexer ${instance_num}
  ${hostname}:
    image: "${SPLUNK_IMAGE}"
    container_name: "\${COMPOSE_PROJECT_NAME:-splunk}_${hostname}"
    hostname: "${hostname}"
    restart: unless-stopped
    ports:
      - "$((9997 + instance_num - 1)):9997"  # Splunk2Splunk
      - "$((8088 + instance_num - 1)):8088"  # HTTP Event Collector
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_indexer"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_INDEXER_URL: "https://${hostname}:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
      SPLUNK_REPLICATION_FACTOR: "${SPLUNK_REPLICATION_FACTOR}"
      SPLUNK_SEARCH_FACTOR: "${SPLUNK_SEARCH_FACTOR}"
    networks:
      - splunk-net
    volumes:
      - splunk-idx${instance_num}-etc:/opt/splunk/etc
      - splunk-idx${instance_num}-var:/opt/splunk/var
    profiles: ["splunk"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "$SPLUNK_HOME/bin/splunk status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_INDEXER_CPU_LIMIT:-2.0}'
          memory: '${SPLUNK_INDEXER_MEM_LIMIT:-4G}'
        reservations:
          cpus: '${SPLUNK_INDEXER_CPU_RESERVE:-1.0}'
          memory: '${SPLUNK_INDEXER_MEM_RESERVE:-2G}'
    depends_on:
      splunk-cm:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - splunk_password
      - splunk_secret
EOF
  fi
}

_generate_splunk_search_head_service() {
  local instance_num="${1:-1}"
  local hostname="splunk-sh${instance_num}"
  local web_port=$((8000 + instance_num - 1))

  cat <<EOF
  # Splunk Search Head ${instance_num}
  ${hostname}:
    image: "${SPLUNK_IMAGE}"
    container_name: "\${COMPOSE_PROJECT_NAME:-splunk}_${hostname}"
    hostname: "${hostname}"
    restart: unless-stopped
    ports:
      - "${web_port}:8000"  # Splunk Web
      - "$((8089 + instance_num + 9)):8089"  # Management port
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_search_head"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_SEARCH_HEAD_URL: "https://${hostname}:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
    networks:
      - splunk-net
    volumes:
      - splunk-sh${instance_num}-etc:/opt/splunk/etc
      - splunk-sh${instance_num}-var:/opt/splunk/var
    profiles: ["splunk"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8000/en-US/account/login >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 120s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_SEARCH_HEAD_CPU_LIMIT:-1.5}'
          memory: '${SPLUNK_SEARCH_HEAD_MEM_LIMIT:-2G}'
        reservations:
          cpus: '${SPLUNK_SEARCH_HEAD_CPU_RESERVE:-0.5}'
          memory: '${SPLUNK_SEARCH_HEAD_MEM_RESERVE:-1G}'
    depends_on:
      splunk-cm:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - splunk_password
      - splunk_secret
EOF
  fi
}

_generate_splunk_cluster_master_service() {
  cat <<EOF
  # Splunk Cluster Master
  splunk-cm:
    image: "${SPLUNK_IMAGE}"
    container_name: "\${COMPOSE_PROJECT_NAME:-splunk}_cluster_master"
    hostname: "splunk-cm"
    restart: unless-stopped
    ports:
      - "8089:8089"  # Management port
    environment:
      SPLUNK_START_ARGS: "--accept-license --answer-yes"
      SPLUNK_ROLE: "splunk_cluster_master"
      SPLUNK_CLUSTER_MASTER_URL: "https://splunk-cm:8089"
      SPLUNK_PASSWORD: "\${SPLUNK_PASSWORD}"
      SPLUNK_SECRET: "\${SPLUNK_SECRET}"
      SPLUNK_REPLICATION_FACTOR: "${SPLUNK_REPLICATION_FACTOR}"
      SPLUNK_SEARCH_FACTOR: "${SPLUNK_SEARCH_FACTOR}"
    networks:
      - splunk-net
    volumes:
      - splunk-cm-etc:/opt/splunk/etc
      - splunk-cm-var:/opt/splunk/var
    profiles: ["splunk"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "$SPLUNK_HOME/bin/splunk status || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${SPLUNK_CM_CPU_LIMIT:-1.0}'
          memory: '${SPLUNK_CM_MEM_LIMIT:-1G}'
        reservations:
          cpus: '${SPLUNK_CM_CPU_RESERVE:-0.5}'
          memory: '${SPLUNK_CM_MEM_RESERVE:-512M}'
    logging:
      driver: "json-file"
      options:
        max-size: "50m"
        max-file: "5"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - splunk_password
      - splunk_secret
EOF
  fi
}

_generate_prometheus_service() {
  cat <<'EOF'
  # Prometheus monitoring service
  prometheus:
    image: "${PROMETHEUS_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_prometheus"
    restart: unless-stopped
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--storage.tsdb.retention.time=15d'
      - '--web.enable-lifecycle'
    ports:
      - "9090:9090"
    networks:
      - app-net
      - splunk-net
    volumes:
      - $(add_selinux_flag_if_needed "./config/prometheus.yml:/etc/prometheus/prometheus.yml:ro")
      - prometheus-data:/prometheus
    profiles: ["monitoring"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:9090/-/healthy || exit 1"]
      interval: 20s
      timeout: 3s
      retries: 10
      start_period: 30s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${PROMETHEUS_CPU_LIMIT:-1}'
          memory: '${PROMETHEUS_MEM_LIMIT:-1G}'
        reservations:
          cpus: '${PROMETHEUS_CPU_RESERVE:-0.5}'
          memory: '${PROMETHEUS_MEM_RESERVE:-512M}'
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

_generate_grafana_service() {
  cat <<'EOF'
  # Grafana dashboard service
  grafana:
    image: "${GRAFANA_IMAGE}"
    container_name: "${COMPOSE_PROJECT_NAME:-myapp}_grafana"
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "${GRAFANA_ADMIN_PASSWORD:-admin}"
      GF_INSTALL_PLUGINS: "grafana-piechart-panel"
    networks:
      - app-net
      - splunk-net
    volumes:
      - grafana-data:/var/lib/grafana
      - $(add_selinux_flag_if_needed "./config/grafana-provisioning/:/etc/grafana/provisioning/:ro")
    profiles: ["monitoring"]
EOF
  if is_true "${ENABLE_HEALTHCHECKS}" && (( COMPOSE_SUPPORTS_HEALTHCHECK == 1 )); then
    cat <<'EOF'
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:3000/api/health | grep -q 'database.*ok'"]
      interval: 20s
      timeout: 5s
      retries: 10
      start_period: 30s
EOF
  fi
  cat <<'EOF'
    deploy:
      resources:
        limits:
          cpus: '${GRAFANA_CPU_LIMIT:-0.5}'
          memory: '${GRAFANA_MEM_LIMIT:-512M}'
        reservations:
          cpus: '${GRAFANA_CPU_RESERVE:-0.2}'
          memory: '${GRAFANA_MEM_RESERVE:-256M}'
    depends_on:
      prometheus:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'
    secrets:
      - grafana_admin_password
EOF
  fi
}

_generate_secrets_block() {
  if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
    cat <<'EOF'

secrets:
  splunk_password:
    file: ./secrets/splunk_password.txt
  splunk_secret:
    file: ./secrets/splunk_secret.txt
  grafana_admin_password:
    file: ./secrets/grafana_admin_password.txt
EOF
  fi
}

_generate_networks_block() {
  cat <<'EOF'

networks:
  app-net:
    driver: bridge
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_network"
EOF
  if is_true "${ENABLE_SPLUNK}"; then
    cat <<'EOF'
  splunk-net:
    driver: bridge
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cluster_network"
EOF
  fi
}

_generate_volumes_block() {
  cat <<'EOF'

volumes:
  app-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_data"
  app-logs:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_app_logs"
  redis-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_redis_data"
EOF
  if is_true "${ENABLE_MONITORING}"; then
    cat <<'EOF'
  prometheus-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_prometheus_data"
  grafana-data:
    name: "${COMPOSE_PROJECT_NAME:-myapp}_grafana_data"
EOF
  fi
  if is_true "${ENABLE_SPLUNK}"; then
    cat <<'EOF'
  splunk-cm-etc:
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cm_etc"
  splunk-cm-var:
    name: "${COMPOSE_PROJECT_NAME:-splunk}_cm_var"
EOF
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      cat <<EOF
  splunk-idx${i}-etc:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_idx${i}_etc"
  splunk-idx${i}-var:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_idx${i}_var"
EOF
    done
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      cat <<EOF
  splunk-sh${i}-etc:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_sh${i}_etc"
  splunk-sh${i}-var:
    name: "\${COMPOSE_PROJECT_NAME:-splunk}_sh${i}_var"
EOF
    done
  fi
}

# ==============================================================================
# Public API
# ==============================================================================

# validate_compose_config
# Validates configuration before generation
validate_compose_config() {
  log_info "Validating compose configuration..."

  # Base images - only required when specific features are enabled
  local base_required=()
  local maybe_required=()
  
  # App services only required when explicitly enabled
  if is_true "${ENABLE_APP_SERVICES:-false}"; then
    base_required+=("APP_IMAGE" "REDIS_IMAGE")
  fi
  
  # Monitoring images required when monitoring is enabled
  if is_true "${ENABLE_MONITORING}"; then
    maybe_required+=("PROMETHEUS_IMAGE" "GRAFANA_IMAGE")
  fi
  
  # Splunk images required when Splunk services are enabled
  if is_true "${ENABLE_SPLUNK}"; then
    maybe_required+=("SPLUNK_IMAGE")
  fi

  # Only validate if we have required variables
  if (( ${#base_required[@]} > 0 )) || (( ${#maybe_required[@]} > 0 )); then
    validate_environment_vars "${base_required[@]}" "${maybe_required[@]}"
  fi

  # Validate Splunk cluster configuration
  if is_true "${ENABLE_SPLUNK}"; then
    validate_rf_sf "${SPLUNK_REPLICATION_FACTOR}" "${SPLUNK_SEARCH_FACTOR}" "${INDEXER_COUNT}" || return 1
    validate_splunk_cluster_size "${INDEXER_COUNT}" "${SEARCH_HEAD_COUNT}" || return 1
  fi

  # Check required secrets (env or files)
  local required_vars=()
  if is_true "${ENABLE_SPLUNK}"; then
    required_vars+=("SPLUNK_PASSWORD" "SPLUNK_SECRET")
    if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
      validate_file_readable ./secrets/splunk_password.txt "Splunk password secret" || return 1
      validate_file_readable ./secrets/splunk_secret.txt "Splunk secret key" || return 1
    fi
  fi
  if is_true "${ENABLE_MONITORING}"; then
    required_vars+=("GRAFANA_ADMIN_PASSWORD")
    if (( COMPOSE_SUPPORTS_SECRETS == 1 )) && is_true "${ENABLE_SECRETS}"; then
      validate_file_readable ./secrets/grafana_admin_password.txt "Grafana admin password secret" || return 1
    fi
  fi
  if [[ ${#required_vars[@]} -gt 0 ]]; then
    validate_environment_vars "${required_vars[@]}"
  fi

  log_success "Compose configuration validation passed"
}

# generate_compose_file <output_path>
generate_compose_file() {
  local out="${1:?output file required}"
  log_info "🔥 Generating Docker Compose at: ${out}"

  begin_step "compose-generation"

  # Validate configuration first
  validate_compose_config

  # temp file; ensure cleanup on failure
  local tmp
  tmp="$(mktemp "${out}.tmp.XXXXXX")"
  register_cleanup "rm -f '${tmp}'"

  # Header
  _generate_header > "${tmp}"
  
  # Add services section header
  echo "" >> "${tmp}"
  echo "services:" >> "${tmp}"

  # Debug: Show current ENABLE_SPLUNK value
  log_message INFO "DEBUG: ENABLE_SPLUNK='${ENABLE_SPLUNK}', is_true result: $(is_true "${ENABLE_SPLUNK}" && echo "TRUE" || echo "FALSE")"

  # For Easy_Splunk toolkit, generate Splunk services first (primary purpose)
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "  -> Splunk cluster enabled: ${INDEXER_COUNT} indexers, ${SEARCH_HEAD_COUNT} search heads"

    # Cluster Master (required for multi-node)
    if [[ "${SPLUNK_CLUSTER_MODE}" == "cluster" ]] || [[ "${INDEXER_COUNT}" -gt 1 ]]; then
      _generate_splunk_cluster_master_service >> "${tmp}"
    fi

    # Generate indexers
    for ((i=1; i<=INDEXER_COUNT; i++)); do
      _generate_splunk_indexer_service "$i" >> "${tmp}"
    done

    # Generate search heads
    for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
      _generate_splunk_search_head_service "$i" >> "${tmp}"
    done
  fi

  # Optional: Generic app services (only if explicitly enabled)
  if is_true "${ENABLE_APP_SERVICES:-false}"; then
    log_info "  -> Generic app services enabled"
    _generate_app_service      >> "${tmp}"
    _generate_redis_service    >> "${tmp}"
  fi

  # Monitoring (via profiles)
  if is_true "${ENABLE_MONITORING}"; then
    log_info "  -> Monitoring enabled: adding Prometheus and Grafana (profile: monitoring)"
    _generate_prometheus_service >> "${tmp}"
    _generate_grafana_service    >> "${tmp}"
  else
    log_info "  -> Monitoring disabled. Enable at runtime with: COMPOSE_PROFILES=monitoring"
  fi

  # Top-level blocks
  _generate_secrets_block  >> "${tmp}"
  _generate_networks_block >> "${tmp}"
  _generate_volumes_block  >> "${tmp}"

  # Add version metadata to the generated compose file
  _add_compose_metadata "${tmp}"

  # Atomic move into place
  atomic_write_file "${tmp}" "${out}"
  log_success "✅ Compose file generated: ${out}"
  complete_step "compose-generation"

  # Validate image references in generated file
  log_info "🔍 Validating image references..."
  if validate_image_references "${out}"; then
    log_success "✅ Image reference validation passed"
  else
    log_error "❌ Image reference validation failed" 
    log_info "Run 'audit_image_references ${out}' for details"
    return 1
  fi

  # Report what was generated
  log_info "Generated services:"
  log_info "  • Application stack: app, redis"
  if is_true "${ENABLE_SPLUNK}"; then
    log_info "  • Splunk cluster: ${INDEXER_COUNT} indexers, ${SEARCH_HEAD_COUNT} search heads"
  fi
  if is_true "${ENABLE_MONITORING}"; then
    log_info "  • Monitoring stack: prometheus, grafana"
  fi
}

# generate_env_template <output_path>
# Generates a .env template file with all configurable variables
generate_env_template() {
  local out="${1:?output file required}"
  log_info "Generating environment template: ${out}"

  begin_step "env-template-generation"
  cat > "${tmp}" <<'EOF'
# ==============================================================================
# Environment Configuration Template
# Generated by lib/compose-generator.sh
# ==============================================================================

# Project Configuration
COMPOSE_PROJECT_NAME=myapp
LOG_LEVEL=info

# Application Configuration
APP_PORT=8080
APP_CPU_LIMIT=1.5
APP_MEM_LIMIT=2G
APP_CPU_RESERVE=0.5
APP_MEM_RESERVE=512M

# Redis Configuration
REDIS_CPU_LIMIT=0.5
REDIS_MEM_LIMIT=512M
REDIS_CPU_RESERVE=0.1
REDIS_MEM_RESERVE=128M

# Splunk Configuration (if ENABLE_SPLUNK=true)
SPLUNK_PASSWORD="\${SPLUNK_PASSWORD}"  # Set via secrets manager or environment
SPLUNK_SECRET="\${SPLUNK_SECRET}"      # Set via secrets manager or environment
SPLUNK_REPLICATION_FACTOR=1
SPLUNK_SEARCH_FACTOR=1
SPLUNK_INDEXER_CPU_LIMIT=2.0
SPLUNK_INDEXER_MEM_LIMIT=4G
SPLUNK_INDEXER_CPU_RESERVE=1.0
SPLUNK_INDEXER_MEM_RESERVE=2G
SPLUNK_SEARCH_HEAD_CPU_LIMIT=1.5
SPLUNK_SEARCH_HEAD_MEM_LIMIT=2G
SPLUNK_SEARCH_HEAD_CPU_RESERVE=0.5
SPLUNK_SEARCH_HEAD_MEM_RESERVE=1G
SPLUNK_CM_CPU_LIMIT=1.0
SPLUNK_CM_MEM_LIMIT=1G
SPLUNK_CM_CPU_RESERVE=0.5
SPLUNK_CM_MEM_RESERVE=512M

# Monitoring Configuration (if ENABLE_MONITORING=true)
GRAFANA_ADMIN_PASSWORD="\${GRAFANA_ADMIN_PASSWORD}"  # Set via secrets manager or environment
PROMETHEUS_CPU_LIMIT=1
PROMETHEUS_MEM_LIMIT=1G
PROMETHEUS_CPU_RESERVE=0.5
PROMETHEUS_MEM_RESERVE=512M
GRAFANA_CPU_LIMIT=0.5
GRAFANA_MEM_LIMIT=512M
GRAFANA_CPU_RESERVE=0.2
GRAFANA_MEM_RESERVE=256M
EOF
  atomic_write_file "${tmp}" "${out}"
  log_success "Environment template generated: ${out}"
  complete_step "env-template-generation"
}

# Add version metadata to generated compose file
_add_compose_metadata() {
  local compose_file="$1"

  if [[ ! -f "$compose_file" ]]; then
    log_message ERROR "Compose file not found: $compose_file"
    return 1
  fi

  # Create backup
  cp "$compose_file" "${compose_file}.backup.$(date +%s)"

  # Create temp file with metadata header
  local temp_file="${compose_file}.meta"
  local timestamp
  timestamp=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

  # Detect compose engine for metadata
  detect_compose_engine 2>/dev/null || true

  cat > "$temp_file" << EOF
# ==============================================================================
# GENERATED COMPOSE FILE - DO NOT EDIT MANUALLY
# -----------------------------------------------------------------------------
# Generated by: compose-generator.sh
# Generated at: $timestamp UTC
# Compose Engine: ${COMPOSE_ENGINE:-unknown}
# Engine Version: ${COMPOSE_ENGINE_VERSION:-unknown}
# Schema Version: ${COMPOSE_SCHEMA_VERSION:-3.8}
# Validation: NOT_RUN (will be validated before deployment)
# -----------------------------------------------------------------------------
# This file was generated for compose schema version ${COMPOSE_SCHEMA_VERSION:-3.8}.
# If you encounter compatibility issues, verify your compose engine version.
# ==============================================================================

EOF

  # Append original content
  cat "$compose_file" >> "$temp_file"

  # Replace original file
  mv "$temp_file" "$compose_file"

  log_message DEBUG "Added version metadata to compose file: $compose_file"
}

# ==============================================================================
# End of lib/compose-generator.sh
