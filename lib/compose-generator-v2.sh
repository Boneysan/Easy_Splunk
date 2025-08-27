#!/usr/bin/env bash
# ==============================================================================
# lib/compose-generator-v2.sh
# Template-based compose file generator (Phase 3 rewrite)
#
# Dependencies: lib/core.sh, lib/compose-config.sh, lib/image-validator.sh, versions.env
# Version: 2.0.0
#
# Usage Examples:
#   generate_compose_file docker-compose.yml
#   generate_env_template .env
# ==============================================================================

# Load image validation library
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${LIB_DIR}/image-validator.sh" ]]; then
    # shellcheck source=/dev/null
    source "${LIB_DIR}/image-validator.sh"
fi

# Fallback functions if core functions not available
if ! type begin_step &>/dev/null; then
    begin_step() { log_info "Starting: $1"; }
fi
if ! type complete_step &>/dev/null; then
    complete_step() { log_info "Completed: $1"; }
fi

# Template engine functions

# render_template <template_file> <config_vars>
# Renders a template file with variable substitution
render_template() {
    local template_file="$1"
    local config_vars="$2"
    
    if [[ ! -f "$template_file" ]]; then
        log_error "Template file not found: $template_file"
        return 1
    fi
    
    local content
    content=$(cat "$template_file")
    
    # Process config variables
    while IFS='=' read -r key value; do
        [[ -n "$key" && -n "$value" ]] || continue
        # Simple variable substitution
        content="${content//\{\{${key}\}\}/${value}}"
    done <<< "$config_vars"
    
    # Process conditional blocks
    content=$(process_conditionals "$content" "$config_vars")
    
    echo "$content"
}

# process_conditionals <content> <config_vars>
# Processes {{#VAR}} and {{/VAR}} conditional blocks
process_conditionals() {
    local content="$1"
    local config_vars="$2"
    
    # Create associative array of config variables
    declare -A config
    while IFS='=' read -r key value; do
        [[ -n "$key" ]] || continue
        config["$key"]="$value"
    done <<< "$config_vars"
    
    # Simple approach: process each conditional block one at a time
    local result="$content"
    local max_iterations=10
    local iteration=0
    
    while [[ $iteration -lt $max_iterations ]]; do
        # Look for the first conditional block
        if [[ "$result" =~ \{\{#([A-Z_]+)\}\} ]]; then
            local var_name="${BASH_REMATCH[1]}"
            local start_tag="{{#${var_name}}}"
            local end_tag="{{/${var_name}}}"
            
            # Find the matching end tag
            local start_pos="${result%%$start_tag*}"
            local start_len=${#start_pos}
            local temp="${result:$start_len}"
            temp="${temp#$start_tag}"
            
            if [[ "$temp" == *"$end_tag"* ]]; then
                local content_part="${temp%%$end_tag*}"
                local after_part="${temp#*$end_tag}"
                
                # Check if variable is true
                if is_true "${config[$var_name]:-false}"; then
                    # Keep content, remove tags
                    result="${result:0:$start_len}${content_part}${after_part}"
                else
                    # Remove entire block
                    result="${result:0:$start_len}${after_part}"
                fi
                
                ((iteration++))
                continue
            fi
        fi
        break
    done
    
    echo "$result"
}

# combine_services <service_list>
# Combines multiple rendered services into services section
combine_services() {
    local service_list="$1"
    
    echo "services:"
    while read -r service_config; do
        [[ -n "$service_config" ]] || continue
        
        local service_name instance_num template_path
        if [[ "$service_config" == *":"* ]]; then
            service_name="${service_config%:*}"
            instance_num="${service_config#*:}"
        else
            service_name="$service_config"
            instance_num="1"
        fi
        
        template_path=$(get_service_template_path "$service_name")
        if [[ -z "$template_path" ]]; then
            log_warning "No template found for service: $service_name"
            continue
        fi
        
        # Get service-specific config
        local service_config_vars
        service_config_vars=$(get_service_config "$service_name" "$instance_num")
        
        # Add global config
        local global_config_vars
        global_config_vars=$(get_global_config)
        
        # Combine configs
        local all_config_vars
        all_config_vars=$(printf '%s\n%s' "$global_config_vars" "$service_config_vars")
        
        # Render service template
        render_template "$template_path" "$all_config_vars"
        
    done <<< "$service_list"
}

# generate_compose_file <output_path>
# Main function to generate complete compose file
generate_compose_file() {
    local output_file="${1:?Output file required}"
    
    log_info "🔥 Generating Docker Compose v2.0 at: ${output_file}"
    begin_step "compose-generation-v2"
    
    # Validate configuration
    validate_config
    
    # Create temporary file
    local tmp_file
    tmp_file=$(mktemp "${output_file}.tmp.XXXXXX")
    register_cleanup "rm -f '${tmp_file}'"
    
    # Get global configuration
    local global_config
    global_config=$(get_global_config)
    
    # Render header
    local header_template="lib/templates/base/header.yml"
    render_template "$header_template" "$global_config" > "$tmp_file"
    
    echo "" >> "$tmp_file"
    
    # Get enabled services and render them
    local enabled_services
    enabled_services=$(get_enabled_services)
    
    if [[ -n "$enabled_services" ]]; then
        combine_services "$enabled_services" >> "$tmp_file"
    else
        log_warning "No services enabled"
        echo "services: {}" >> "$tmp_file"
    fi
    
    # Add networks section
    echo "" >> "$tmp_file"
    local networks_template="lib/templates/base/networks.yml"
    render_template "$networks_template" "$global_config" >> "$tmp_file"
    
    # Add volumes section  
    echo "" >> "$tmp_file"
    local volumes_template="lib/templates/base/volumes.yml"
    local volume_config
    volume_config=$(get_volume_config)
    local volumes_config
    volumes_config=$(printf '%s\n%s' "$global_config" "$volume_config")
    render_template "$volumes_template" "$volumes_config" >> "$tmp_file"
    
    # Add secrets section if enabled
    if is_true "${ENABLE_SECRETS:-false}"; then
        echo "" >> "$tmp_file"
        local secrets_template="lib/templates/base/secrets.yml"
        render_template "$secrets_template" "$global_config" >> "$tmp_file"
    fi
    
    # Atomic move to final location
    atomic_write_file "$tmp_file" "$output_file"
    
    log_success "✅ Compose file v2.0 generated: ${output_file}"
    complete_step "compose-generation-v2"
    
    # Validate image references in generated file
    log_info "🔍 Validating image references..."
    if validate_image_references "$output_file"; then
        log_success "✅ Image reference validation passed"
    else
        log_error "❌ Image reference validation failed"
        log_info "Run 'audit_image_references $output_file' for details"
        return 1
    fi
    
    # Report what was generated
    log_info "Generated services:"
    while read -r service; do
        [[ -n "$service" ]] || continue
        log_info "  • $service"
    done <<< "$enabled_services"
}

# generate_env_template <output_path>
# Generates environment template (unchanged from v1)
generate_env_template() {
    local output_file="${1:?Output file required}"
    log_info "Generating environment template: ${output_file}"
    
    begin_step "env-template-generation"
    
    local tmp_file
    tmp_file=$(mktemp "${output_file}.tmp.XXXXXX")
    register_cleanup "rm -f '${tmp_file}'"
    
    cat > "$tmp_file" <<'EOF'
# ==============================================================================
# Environment Configuration Template
# Generated by lib/compose-generator.sh v2.0
# ==============================================================================

# Project Configuration
COMPOSE_PROJECT_NAME=myapp
LOG_LEVEL=info

# Splunk Configuration
ENABLE_SPLUNK=true
SPLUNK_CLUSTER_MODE=cluster
INDEXER_COUNT=2
SEARCH_HEAD_COUNT=1
SPLUNK_REPLICATION_FACTOR=1
SPLUNK_SEARCH_FACTOR=1
SPLUNK_PASSWORD="${SPLUNK_PASSWORD}"
SPLUNK_SECRET="${SPLUNK_SECRET}"

# Monitoring Configuration  
ENABLE_MONITORING=true
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"

# Resource Limits
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

PROMETHEUS_CPU_LIMIT=1
PROMETHEUS_MEM_LIMIT=1G
PROMETHEUS_CPU_RESERVE=0.5
PROMETHEUS_MEM_RESERVE=512M

GRAFANA_CPU_LIMIT=0.5
GRAFANA_MEM_LIMIT=512M
GRAFANA_CPU_RESERVE=0.2
GRAFANA_MEM_RESERVE=256M
EOF

    atomic_write_file "$tmp_file" "$output_file"
    log_success "Environment template generated: ${output_file}"
    complete_step "env-template-generation"
}
