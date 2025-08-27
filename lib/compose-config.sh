#!/usr/bin/env bash
# ==============================================================================
# lib/compose-config.sh
# Configuration management for compose generation
#
# Purpose: Pure configuration functions for service definitions, 
#          network configurations, and volume configurations.
#          Separates configuration logic from template rendering.
#
# Dependencies: lib/core.sh, versions.env
# Version: 2.0.0
# ==============================================================================

# Service registry mapping service names to template files
declare -gA SERVICE_TEMPLATES=(
    ["splunk-cluster-master"]="lib/templates/services/splunk-cluster-master.yml"
    ["splunk-indexer"]="lib/templates/services/splunk-indexer.yml"
    ["splunk-search-head"]="lib/templates/services/splunk-search-head.yml"
    ["prometheus"]="lib/templates/services/prometheus.yml"
    ["grafana"]="lib/templates/services/grafana.yml"
)

# Service dependency mapping
declare -gA SERVICE_DEPENDENCIES=(
    ["splunk-indexer"]="splunk-cluster-master"
    ["splunk-search-head"]="splunk-cluster-master"
    ["grafana"]="prometheus"
)

# Service profile mapping  
declare -gA SERVICE_PROFILES=(
    ["splunk-cluster-master"]="splunk"
    ["splunk-indexer"]="splunk"
    ["splunk-search-head"]="splunk"
    ["prometheus"]="monitoring"
    ["grafana"]="monitoring"
)

# get_enabled_services
# Returns list of enabled services based on configuration
get_enabled_services() {
    local services=()
    
    # Splunk services
    if is_true "${ENABLE_SPLUNK:-true}"; then
        # Add cluster master if multi-node or explicitly clustered
        if [[ "${SPLUNK_CLUSTER_MODE}" == "cluster" ]] || [[ "${INDEXER_COUNT:-1}" -gt 1 ]]; then
            services+=("splunk-cluster-master")
        fi
        
        # Add indexers
        for ((i=1; i<=INDEXER_COUNT; i++)); do
            services+=("splunk-indexer:${i}")
        done
        
        # Add search heads  
        for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
            services+=("splunk-search-head:${i}")
        done
    fi
    
    # Monitoring services
    if is_true "${ENABLE_MONITORING:-false}"; then
        services+=("prometheus" "grafana")
    fi
    
    printf '%s\n' "${services[@]}"
}

# get_service_config <service_name> [instance_num]
# Returns configuration variables for a service instance
get_service_config() {
    local service_name="$1"
    local instance_num="${2:-1}"
    
    case "$service_name" in
        "splunk-indexer")
            echo "INSTANCE_NUM=${instance_num}"
            echo "SPLUNK_PORT=$((9997 + instance_num - 1))" 
            echo "HEC_PORT=$((8088 + instance_num - 1))"
            echo "SPLUNK_REPLICATION_FACTOR=${SPLUNK_REPLICATION_FACTOR:-1}"
            echo "SPLUNK_SEARCH_FACTOR=${SPLUNK_SEARCH_FACTOR:-1}"
            ;;
        "splunk-search-head")
            echo "INSTANCE_NUM=${instance_num}"
            echo "WEB_PORT=$((8000 + instance_num - 1))"
            echo "MGMT_PORT=$((8089 + instance_num + 9))"
            ;;
        "splunk-cluster-master")
            echo "SPLUNK_REPLICATION_FACTOR=${SPLUNK_REPLICATION_FACTOR:-1}"
            echo "SPLUNK_SEARCH_FACTOR=${SPLUNK_SEARCH_FACTOR:-1}"
            ;;
        "prometheus")
            ;;
        "grafana")
            ;;
    esac
}

# get_global_config
# Returns global configuration variables for template rendering
get_global_config() {
    echo "TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-unknown}"
    echo "COMPOSE_IMPL=${COMPOSE_IMPL:-unknown}"
    echo "ENABLE_HEALTHCHECKS=${ENABLE_HEALTHCHECKS:-true}"
    echo "ENABLE_SECRETS=${ENABLE_SECRETS:-false}"
    echo "ENABLE_SPLUNK=${ENABLE_SPLUNK:-true}"
    echo "ENABLE_MONITORING=${ENABLE_MONITORING:-false}"
    echo "COMPOSE_SUPPORTS_HEALTHCHECK=${COMPOSE_SUPPORTS_HEALTHCHECK:-1}"
    echo "COMPOSE_SUPPORTS_SECRETS=${COMPOSE_SUPPORTS_SECRETS:-0}"
}

# get_volume_config
# Returns volume configuration for template rendering
get_volume_config() {
    local volumes=()
    
    # Splunk volumes
    if is_true "${ENABLE_SPLUNK:-true}"; then
        # Indexer volumes
        for ((i=1; i<=INDEXER_COUNT; i++)); do
            volumes+=("INDEX=${i}")
        done
        echo "SPLUNK_INDEXER_VOLUMES=$(printf '%s\n' "${volumes[@]}")"
        
        volumes=()
        # Search head volumes
        for ((i=1; i<=SEARCH_HEAD_COUNT; i++)); do
            volumes+=("INDEX=${i}")
        done
        echo "SPLUNK_SEARCH_HEAD_VOLUMES=$(printf '%s\n' "${volumes[@]}")"
    fi
}

# validate_config
# Validates all configuration settings
validate_config() {
    log_info "Validating compose configuration..."
    
    # Validate indexer/search head counts
    if [[ "${INDEXER_COUNT:-1}" -lt 1 ]]; then
        die "${E_INVALID_INPUT:-1}" "INDEXER_COUNT must be >= 1"
    fi
    
    if [[ "${SEARCH_HEAD_COUNT:-1}" -lt 1 ]]; then
        die "${E_INVALID_INPUT:-1}" "SEARCH_HEAD_COUNT must be >= 1"
    fi
    
    # Validate replication factors if using Splunk
    if is_true "${ENABLE_SPLUNK:-true}"; then
        local rf="${SPLUNK_REPLICATION_FACTOR:-1}"
        local sf="${SPLUNK_SEARCH_FACTOR:-1}"
        local indexer_count="${INDEXER_COUNT:-1}"
        
        if [[ "$rf" -gt "$indexer_count" ]]; then
            log_warning "Replication factor ($rf) exceeds indexer count ($indexer_count)"
        fi
        
        if [[ "$sf" -gt "$indexer_count" ]]; then
            log_warning "Search factor ($sf) exceeds indexer count ($indexer_count)"
        fi
    fi
    
    # Validate required images exist
    local required_images=()
    if is_true "${ENABLE_SPLUNK:-true}"; then
        required_images+=("SPLUNK_IMAGE")
    fi
    if is_true "${ENABLE_MONITORING:-false}"; then
        required_images+=("PROMETHEUS_IMAGE" "GRAFANA_IMAGE")
    fi
    
    for img_var in "${required_images[@]}"; do
        if [[ -z "${!img_var:-}" ]]; then
            die "${E_INVALID_INPUT:-1}" "Required image variable $img_var is not set"
        fi
    done
    
    log_success "Configuration validation complete"
}

# get_service_template_path <service_name>
# Returns the template file path for a service
get_service_template_path() {
    local service_name="$1"
    echo "${SERVICE_TEMPLATES[$service_name]:-}"
}

# get_service_profile <service_name>
# Returns the profile for a service
get_service_profile() {
    local service_name="$1"
    echo "${SERVICE_PROFILES[$service_name]:-}"
}
