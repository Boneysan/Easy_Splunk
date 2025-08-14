#!/bin/bash
# ==============================================================================
# scripts/backup/backup_manager.sh
# Automated backup and recovery system for Splunk clusters
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"

# Configuration
readonly BACKUP_BASE_DIR="${BACKUP_BASE_DIR:-/opt/splunk/backups}"
readonly BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
readonly SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
readonly CONFIG_BACKUP_PATHS=(
    "etc/system"
    "etc/apps"
    "etc/users"
    "etc/deployment-apps"
    "etc/master-apps"
    "etc/shcluster"
)

create_cluster_backup() {
    local backup_type="${1:-full}"
    local backup_name="splunk_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_dir="${BACKUP_BASE_DIR}/${backup_name}"
    
    log_info "Creating cluster backup: ${backup_name}"
    log_info "Backup type: ${backup_type}"
    
    # Create backup directory
    mkdir -p "${backup_dir}"
    
    # Create backup metadata
    create_backup_metadata "${backup_dir}" "${backup_type}"
    
    # Perform backup based on type
    case "${backup_type}" in
        "config")
            backup_configurations "${backup_dir}"
            ;;
        "full")
            backup_configurations "${backup_dir}"
            backup_indexes "${backup_dir}"
            backup_custom_apps "${backup_dir}"
            backup_certificates "${backup_dir}"
            ;;
        "indexes")
            backup_indexes "${backup_dir}"
            ;;
        *)
            error_exit "Invalid backup type: ${backup_type}. Use: config, indexes, or full"
            ;;
    esac
    
    # Create backup manifest
    create_backup_manifest "${backup_dir}"
    
    # Validate backup integrity
    validate_backup_integrity "${backup_dir}"
    
    # Compress backup
    log_info "Compressing backup..."
    tar -czf "${backup_dir}.tar.gz" -C "${BACKUP_BASE_DIR}" "${backup_name}"
    
    # Verify compressed backup
    if tar -tzf "${backup_dir}.tar.gz" >/dev/null 2>&1; then
        rm -rf "${backup_dir}"
        log_success "Backup completed successfully: ${backup_dir}.tar.gz"
        
        # Update backup registry
        register_backup "${backup_dir}.tar.gz" "${backup_type}"
        
        # Cleanup old backups
        cleanup_old_backups
    else
        error_exit "Backup compression failed"
    fi
}

backup_configurations() {
    local backup_dir="$1"
    local config_backup_dir="${backup_dir}/configurations"
    
    log_info "Backing up Splunk configurations..."
    mkdir -p "${config_backup_dir}"
    
    # Stop Splunk services for consistent backup
    if splunk status >/dev/null 2>&1; then
        log_info "Stopping Splunk for configuration backup..."
        splunk stop
        local splunk_was_running=true
    else
        local splunk_was_running=false
    fi
    
    # Backup configuration directories
    for config_path in "${CONFIG_BACKUP_PATHS[@]}"; do
        local source_path="${SPLUNK_HOME}/${config_path}"
        local dest_path="${config_backup_dir}/${config_path}"
        
        if [[ -d "${source_path}" ]]; then
            log_info "Backing up ${config_path}..."
            mkdir -p "$(dirname "${dest_path}")"
            cp -R "${source_path}" "${dest_path}"
        else
            log_warning "Configuration path not found: ${source_path}"
        fi
    done
    
    # Backup important files
    backup_important_files "${config_backup_dir}"
    
    # Restart Splunk if it was running
    if [[ "${splunk_was_running}" == "true" ]]; then
        log_info "Restarting Splunk..."
        splunk start
    fi
    
    log_success "Configuration backup completed"
}

backup_indexes() {
    local backup_dir="$1"
    local indexes_backup_dir="${backup_dir}/indexes"
    
    log_info "Backing up Splunk indexes..."
    mkdir -p "${indexes_backup_dir}"
    
    # Get list of indexes to backup
    local indexes
    indexes=$(get_backup_indexes)
    
    if [[ -z "${indexes}" ]]; then
        log_warning "No indexes specified for backup"
        return 0
    fi
    
    # Create index snapshots
    for index in ${indexes}; do
        log_info "Creating snapshot for index: ${index}"
        create_index_snapshot "${index}" "${indexes_backup_dir}"
    done
    
    log_success "Index backup completed"
}

backup_custom_apps() {
    local backup_dir="$1"
    local apps_backup_dir="${backup_dir}/custom_apps"
    
    log_info "Backing up custom applications..."
    mkdir -p "${apps_backup_dir}"
    
    # Find custom apps (non-Splunk apps)
    local custom_apps
    custom_apps=$(find "${SPLUNK_HOME}/etc/apps" -maxdepth 1 -type d -name "*" ! -name "." ! -name ".." ! -name "splunk_*" ! -name "SA-*" ! -name "TA-*" 2>/dev/null || true)
    
    if [[ -n "${custom_apps}" ]]; then
        while IFS= read -r app_path; do
            local app_name
            app_name=$(basename "${app_path}")
            log_info "Backing up custom app: ${app_name}"
            cp -R "${app_path}" "${apps_backup_dir}/"
        done <<< "${custom_apps}"
    else
        log_info "No custom applications found"
    fi
    
    log_success "Custom applications backup completed"
}

backup_certificates() {
    local backup_dir="$1"
    local certs_backup_dir="${backup_dir}/certificates"
    
    log_info "Backing up SSL certificates..."
    mkdir -p "${certs_backup_dir}"
    
    # Find and backup certificate files
    local cert_patterns=("*.pem" "*.crt" "*.key" "*.p12" "*.pfx")
    
    for pattern in "${cert_patterns[@]}"; do
        find "${SPLUNK_HOME}" -name "${pattern}" -type f 2>/dev/null | while read -r cert_file; do
            local relative_path
            relative_path=$(realpath --relative-to="${SPLUNK_HOME}" "${cert_file}")
            local dest_dir
            dest_dir=$(dirname "${certs_backup_dir}/${relative_path}")
            
            mkdir -p "${dest_dir}"
            cp "${cert_file}" "${certs_backup_dir}/${relative_path}"
            log_info "Backed up certificate: ${relative_path}"
        done
    done
    
    log_success "Certificate backup completed"
}

create_index_snapshot() {
    local index_name="$1"
    local backup_dir="$2"
    local index_path="${SPLUNK_HOME}/var/lib/splunk/${index_name}"
    
    if [[ -d "${index_path}" ]]; then
        # Create index metadata
        create_index_metadata "${index_name}" "${backup_dir}"
        
        # Copy index data (for small indexes only)
        local index_size
        index_size=$(du -sh "${index_path}" | cut -f1)
        log_info "Index ${index_name} size: ${index_size}"
        
        # For large indexes, create manifest instead of full copy
        if [[ $(du -s "${index_path}" | cut -f1) -gt 1048576 ]]; then  # > 1GB
            log_warning "Index ${index_name} is large (${index_size}), creating manifest only"
            create_index_manifest "${index_name}" "${backup_dir}"
        else
            log_info "Copying index data for ${index_name}..."
            cp -R "${index_path}" "${backup_dir}/"
        fi
    else
        log_error "Index path not found: ${index_path}"
    fi
}

restore_from_backup() {
    local backup_file="$1"
    local restore_options="${2:-config-only}"
    
    log_info "Starting restore from backup: ${backup_file}"
    log_info "Restore options: ${restore_options}"
    
    # Validate backup file
    validate_backup_file "${backup_file}"
    
    # Create temporary directory for extraction
    local temp_dir
    temp_dir=$(mktemp -d)
    trap "rm -rf ${temp_dir}" EXIT
    
    # Extract backup
    log_info "Extracting backup..."
    tar -xzf "${backup_file}" -C "${temp_dir}"
    
    # Find backup directory
    local backup_dir
    backup_dir=$(find "${temp_dir}" -maxdepth 1 -type d -name "splunk_backup_*" | head -1)
    
    if [[ -z "${backup_dir}" ]]; then
        error_exit "Invalid backup file structure"
    fi
    
    # Validate backup integrity
    validate_backup_integrity "${backup_dir}"
    
    # Perform restore based on options
    case "${restore_options}" in
        "config-only")
            restore_configurations "${backup_dir}"
            ;;
        "full")
            restore_configurations "${backup_dir}"
            restore_indexes "${backup_dir}"
            restore_custom_apps "${backup_dir}"
            restore_certificates "${backup_dir}"
            ;;
        "indexes-only")
            restore_indexes "${backup_dir}"
            ;;
        "apps-only")
            restore_custom_apps "${backup_dir}"
            ;;
        *)
            error_exit "Invalid restore option: ${restore_options}. Use: config-only, full, indexes-only, or apps-only"
            ;;
    esac
    
    log_success "Restore completed successfully"
}

restore_configurations() {
    local backup_dir="$1"
    local config_backup_dir="${backup_dir}/configurations"
    
    if [[ ! -d "${config_backup_dir}" ]]; then
        log_warning "No configuration backup found in this backup"
        return 0
    fi
    
    log_info "Restoring Splunk configurations..."
    
    # Stop Splunk before restore
    if splunk status >/dev/null 2>&1; then
        log_info "Stopping Splunk for configuration restore..."
        splunk stop
        local restart_splunk=true
    else
        local restart_splunk=false
    fi
    
    # Backup current configuration
    local current_backup_dir="${BACKUP_BASE_DIR}/pre_restore_$(date +%Y%m%d_%H%M%S)"
    log_info "Creating backup of current configuration..."
    backup_configurations "${current_backup_dir}"
    
    # Restore configurations
    for config_path in "${CONFIG_BACKUP_PATHS[@]}"; do
        local source_path="${config_backup_dir}/${config_path}"
        local dest_path="${SPLUNK_HOME}/${config_path}"
        
        if [[ -d "${source_path}" ]]; then
            log_info "Restoring ${config_path}..."
            rm -rf "${dest_path}"
            cp -R "${source_path}" "${dest_path}"
            
            # Set proper ownership
            chown -R splunk:splunk "${dest_path}" 2>/dev/null || true
        fi
    done
    
    # Restore important files
    restore_important_files "${config_backup_dir}"
    
    # Restart Splunk if needed
    if [[ "${restart_splunk}" == "true" ]]; then
        log_info "Starting Splunk..."
        splunk start
    fi
    
    log_success "Configuration restore completed"
}

validate_backup_file() {
    local backup_file="$1"
    
    if [[ ! -f "${backup_file}" ]]; then
        error_exit "Backup file not found: ${backup_file}"
    fi
    
    if ! tar -tzf "${backup_file}" >/dev/null 2>&1; then
        error_exit "Invalid backup file format: ${backup_file}"
    fi
    
    log_info "Backup file validation passed"
}

create_backup_metadata() {
    local backup_dir="$1"
    local backup_type="$2"
    local metadata_file="${backup_dir}/backup_metadata.json"
    
    cat > "${metadata_file}" << EOF
{
    "backup_timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "backup_type": "${backup_type}",
    "splunk_version": "$(splunk version --accept-license | head -1 || echo 'Unknown')",
    "hostname": "$(hostname)",
    "backup_size": "0",
    "checksum": "",
    "components": []
}
EOF
}

create_backup_manifest() {
    local backup_dir="$1"
    local manifest_file="${backup_dir}/MANIFEST"
    
    log_info "Creating backup manifest..."
    
    # Generate file list with checksums
    find "${backup_dir}" -type f ! -name "MANIFEST" -exec sha256sum {} \; > "${manifest_file}"
    
    # Update metadata with backup size
    local backup_size
    backup_size=$(du -sh "${backup_dir}" | cut -f1)
    
    # Update metadata file
    local metadata_file="${backup_dir}/backup_metadata.json"
    if [[ -f "${metadata_file}" ]]; then
        # Update backup size in metadata (simplified approach)
        sed -i.bak "s/\"backup_size\": \"0\"/\"backup_size\": \"${backup_size}\"/" "${metadata_file}"
    fi
}

validate_backup_integrity() {
    local backup_dir="$1"
    local manifest_file="${backup_dir}/MANIFEST"
    
    if [[ ! -f "${manifest_file}" ]]; then
        log_warning "No manifest file found, skipping integrity check"
        return 0
    fi
    
    log_info "Validating backup integrity..."
    
    # Verify checksums
    if cd "${backup_dir}" && sha256sum -c MANIFEST >/dev/null 2>&1; then
        log_success "Backup integrity validation passed"
    else
        error_exit "Backup integrity validation failed"
    fi
}

list_backups() {
    log_info "Available backups:"
    
    if [[ ! -d "${BACKUP_BASE_DIR}" ]]; then
        log_warning "Backup directory does not exist: ${BACKUP_BASE_DIR}"
        return 0
    fi
    
    find "${BACKUP_BASE_DIR}" -name "*.tar.gz" -type f -printf '%T@ %p\n' | \
        sort -nr | \
        while read -r timestamp backup_file; do
            local backup_name
            backup_name=$(basename "${backup_file}" .tar.gz)
            local backup_date
            backup_date=$(date -d "@${timestamp}" '+%Y-%m-%d %H:%M:%S')
            local backup_size
            backup_size=$(du -sh "${backup_file}" | cut -f1)
            
            echo "  ${backup_name} (${backup_date}) - ${backup_size}"
        done
}

cleanup_old_backups() {
    log_info "Cleaning up old backups (older than ${BACKUP_RETENTION_DAYS} days)..."
    
    local deleted_count=0
    while IFS= read -r -d '' backup_file; do
        rm -f "${backup_file}"
        ((deleted_count++))
        log_info "Deleted old backup: $(basename "${backup_file}")"
    done < <(find "${BACKUP_BASE_DIR}" -name "*.tar.gz" -type f -mtime +${BACKUP_RETENTION_DAYS} -print0 2>/dev/null)
    
    if [[ ${deleted_count} -eq 0 ]]; then
        log_info "No old backups to clean up"
    else
        log_success "Cleaned up ${deleted_count} old backup(s)"
    fi
}

main() {
    local action="${1:-}"
    
    case "${action}" in
        "create")
            local backup_type="${2:-full}"
            create_cluster_backup "${backup_type}"
            ;;
        "restore")
            local backup_file="${2:-}"
            local restore_options="${3:-config-only}"
            if [[ -z "${backup_file}" ]]; then
                error_exit "Backup file required for restore operation"
            fi
            restore_from_backup "${backup_file}" "${restore_options}"
            ;;
        "list")
            list_backups
            ;;
        "cleanup")
            cleanup_old_backups
            ;;
        *)
            cat << EOF
Usage: $0 {create|restore|list|cleanup}

Commands:
    create [type]           Create a new backup (type: config, indexes, full)
    restore <file> [opts]   Restore from backup file (opts: config-only, full, indexes-only, apps-only)
    list                    List available backups
    cleanup                 Remove old backups

Examples:
    $0 create full
    $0 restore /backups/splunk_backup_20250814_120000.tar.gz config-only
    $0 list
    $0 cleanup
EOF
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
