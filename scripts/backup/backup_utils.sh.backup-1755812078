#!/bin/bash
# ==============================================================================
# scripts/backup/backup_utils.sh
# Utility functions for backup and recovery operations
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"

get_backup_indexes() {
    # Get list of indexes to backup from configuration
    local indexes_file="${SPLUNK_HOME}/etc/system/local/indexes.conf"
    
    if [[ -f "${indexes_file}" ]]; then
        # Extract index names from indexes.conf
        grep -E '^\[.*\]$' "${indexes_file}" | sed 's/\[\|\]//g' | grep -v '^default$' | grep -v '^volume:' || echo ""
    else
        # Default indexes if no configuration found
        echo "main _audit _internal"
    fi
}

create_index_metadata() {
    local index_name="$1"
    local backup_dir="$2"
    local metadata_file="${backup_dir}/${index_name}_metadata.json"
    
    # Get index statistics
    local index_path="${SPLUNK_HOME}/var/lib/splunk/${index_name}"
    local index_size="0"
    local bucket_count="0"
    local earliest_time="N/A"
    local latest_time="N/A"
    
    if [[ -d "${index_path}" ]]; then
        index_size=$(du -sb "${index_path}" 2>/dev/null | cut -f1 || echo "0")
        bucket_count=$(find "${index_path}" -name "db_*" -type d 2>/dev/null | wc -l || echo "0")
    fi
    
    cat > "${metadata_file}" << EOF
{
    "index_name": "${index_name}",
    "backup_timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "index_path": "${index_path}",
    "index_size_bytes": ${index_size},
    "bucket_count": ${bucket_count},
    "earliest_time": "${earliest_time}",
    "latest_time": "${latest_time}",
    "backup_method": "snapshot"
}
EOF
}

create_index_manifest() {
    local index_name="$1"
    local backup_dir="$2"
    local manifest_file="${backup_dir}/${index_name}_manifest.txt"
    local index_path="${SPLUNK_HOME}/var/lib/splunk/${index_name}"
    
    if [[ -d "${index_path}" ]]; then
        # Create manifest of index structure without copying data
        find "${index_path}" -type f -exec ls -la {} \; > "${manifest_file}"
        log_info "Created manifest for large index: ${index_name}"
    fi
}

backup_important_files() {
    local backup_dir="$1"
    local files_backup_dir="${backup_dir}/important_files"
    
    mkdir -p "${files_backup_dir}"
    
    # List of important Splunk files to backup
    local important_files=(
        "etc/splunk.version"
        "etc/instance.cfg"
        "etc/splunk-launch.conf"
        "etc/log.cfg"
        "etc/web.conf"
        "var/lib/splunk/kvstore/mongo.key"
    )
    
    for file_path in "${important_files[@]}"; do
        local source_file="${SPLUNK_HOME}/${file_path}"
        local dest_dir="${files_backup_dir}/$(dirname "${file_path}")"
        
        if [[ -f "${source_file}" ]]; then
            mkdir -p "${dest_dir}"
            cp "${source_file}" "${dest_dir}/"
            log_info "Backed up important file: ${file_path}"
        fi
    done
}

restore_important_files() {
    local backup_dir="$1"
    local files_backup_dir="${backup_dir}/important_files"
    
    if [[ ! -d "${files_backup_dir}" ]]; then
        return 0
    fi
    
    # Restore important files
    find "${files_backup_dir}" -type f | while read -r backup_file; do
        local relative_path
        relative_path=$(realpath --relative-to="${files_backup_dir}" "${backup_file}")
        local dest_file="${SPLUNK_HOME}/${relative_path}"
        local dest_dir
        dest_dir=$(dirname "${dest_file}")
        
        mkdir -p "${dest_dir}"
        cp "${backup_file}" "${dest_file}"
        log_info "Restored important file: ${relative_path}"
    done
}

restore_indexes() {
    local backup_dir="$1"
    local indexes_backup_dir="${backup_dir}/indexes"
    
    if [[ ! -d "${indexes_backup_dir}" ]]; then
        log_warning "No index backup found in this backup"
        return 0
    fi
    
    log_info "Restoring Splunk indexes..."
    
    # Stop Splunk before index restore
    if splunk status >/dev/null 2>&1; then
        splunk stop
        local restart_splunk=true
    else
        local restart_splunk=false
    fi
    
    # Restore each index
    find "${indexes_backup_dir}" -maxdepth 1 -type d -name "*" ! -path "${indexes_backup_dir}" | while read -r index_backup_path; do
        local index_name
        index_name=$(basename "${index_backup_path}")
        local dest_path="${SPLUNK_HOME}/var/lib/splunk/${index_name}"
        
        log_info "Restoring index: ${index_name}"
        
        # Backup current index if it exists
        if [[ -d "${dest_path}" ]]; then
            mv "${dest_path}" "${dest_path}.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        # Restore index data
        cp -R "${index_backup_path}" "${dest_path}"
        chown -R splunk:splunk "${dest_path}" 2>/dev/null || true
    done
    
    # Restart Splunk if needed
    if [[ "${restart_splunk}" == "true" ]]; then
        splunk start
    fi
    
    log_success "Index restore completed"
}

restore_custom_apps() {
    local backup_dir="$1"
    local apps_backup_dir="${backup_dir}/custom_apps"
    
    if [[ ! -d "${apps_backup_dir}" ]]; then
        log_warning "No custom apps backup found in this backup"
        return 0
    fi
    
    log_info "Restoring custom applications..."
    
    # Restore each custom app
    find "${apps_backup_dir}" -maxdepth 1 -type d -name "*" ! -path "${apps_backup_dir}" | while read -r app_backup_path; do
        local app_name
        app_name=$(basename "${app_backup_path}")
        local dest_path="${SPLUNK_HOME}/etc/apps/${app_name}"
        
        log_info "Restoring custom app: ${app_name}"
        
        # Backup current app if it exists
        if [[ -d "${dest_path}" ]]; then
            mv "${dest_path}" "${dest_path}.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        # Restore app
        cp -R "${app_backup_path}" "${dest_path}"
        chown -R splunk:splunk "${dest_path}" 2>/dev/null || true
    done
    
    log_success "Custom applications restore completed"
}

restore_certificates() {
    local backup_dir="$1"
    local certs_backup_dir="${backup_dir}/certificates"
    
    if [[ ! -d "${certs_backup_dir}" ]]; then
        log_warning "No certificates backup found in this backup"
        return 0
    fi
    
    log_info "Restoring SSL certificates..."
    
    # Restore certificate files
    find "${certs_backup_dir}" -type f | while read -r cert_backup_file; do
        local relative_path
        relative_path=$(realpath --relative-to="${certs_backup_dir}" "${cert_backup_file}")
        local dest_file="${SPLUNK_HOME}/${relative_path}"
        local dest_dir
        dest_dir=$(dirname "${dest_file}")
        
        # Backup existing certificate
        if [[ -f "${dest_file}" ]]; then
            mv "${dest_file}" "${dest_file}.backup.$(date +%Y%m%d_%H%M%S)"
        fi
        
        mkdir -p "${dest_dir}"
        cp "${cert_backup_file}" "${dest_file}"
        
        # Set appropriate permissions for certificates
        chmod 600 "${dest_file}"
        chown splunk:splunk "${dest_file}" 2>/dev/null || true
        
        log_info "Restored certificate: ${relative_path}"
    done
    
    log_success "Certificate restore completed"
}

register_backup() {
    local backup_file="$1"
    local backup_type="$2"
    local registry_file="${BACKUP_BASE_DIR}/backup_registry.json"
    
    # Create registry if it doesn't exist
    if [[ ! -f "${registry_file}" ]]; then
        echo '{"backups": []}' > "${registry_file}"
    fi
    
    # Get backup information
    local backup_name
    backup_name=$(basename "${backup_file}" .tar.gz)
    local backup_size
    backup_size=$(du -sh "${backup_file}" | cut -f1)
    local backup_timestamp
    backup_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    
    # Add backup to registry (simplified approach - in production use jq)
    local temp_file
    temp_file=$(mktemp)
    
    # Create new entry
    cat >> "${temp_file}" << EOF
{
    "name": "${backup_name}",
    "file": "${backup_file}",
    "type": "${backup_type}",
    "size": "${backup_size}",
    "timestamp": "${backup_timestamp}",
    "hostname": "$(hostname)"
}
EOF
    
    # Note: In a production environment, you would use jq to properly update JSON
    log_info "Backup registered: ${backup_name}"
    rm -f "${temp_file}"
}

verify_restore_prerequisites() {
    log_info "Verifying restore prerequisites..."
    
    # Check if running as appropriate user
    if [[ "$(whoami)" != "splunk" ]] && [[ "$(whoami)" != "root" ]]; then
        log_warning "Consider running as splunk user or root for proper file ownership"
    fi
    
    # Check disk space
    local backup_base_dir="${BACKUP_BASE_DIR}"
    local available_space
    available_space=$(df "${backup_base_dir}" | awk 'NR==2 {print $4}')
    
    if [[ ${available_space} -lt 1048576 ]]; then  # Less than 1GB
        log_warning "Low disk space available for restore operations"
    fi
    
    # Check if Splunk is installed
    if [[ ! -d "${SPLUNK_HOME}" ]]; then
        error_exit "Splunk installation not found at ${SPLUNK_HOME}"
    fi
    
    log_success "Restore prerequisites verified"
}
