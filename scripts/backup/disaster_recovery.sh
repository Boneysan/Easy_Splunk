#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# scripts/backup/disaster_recovery.sh
# Disaster recovery procedures for Splunk clusters
# ==============================================================================


# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load

# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi

# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi

# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi

# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi

# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi

# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi
# END: Fallback functions for error handling library compatibility


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
source "${SCRIPT_DIR}/../../lib/core.sh"
source "${SCRIPT_DIR}/../../lib/error-handling.sh"
source "${SCRIPT_DIR}/backup_utils.sh"
source "${SCRIPT_DIR}/../../lib/run-with-log.sh"

# Configuration
readonly DR_CONFIG_FILE="${SCRIPT_DIR}/disaster_recovery.conf"
readonly DR_LOG_FILE="/var/log/splunk_disaster_recovery.log"

initialize_disaster_recovery() {
    log_info "Initializing disaster recovery procedures..."
    
    # Create DR configuration if it doesn't exist
    create_dr_config
    
    # Validate DR prerequisites
    validate_dr_prerequisites
    
    # Create recovery procedures documentation
    create_recovery_procedures
    
    log_success "Disaster recovery initialization completed"
}

create_dr_config() {
    if [[ -f "${DR_CONFIG_FILE}" ]]; then
        log_info "DR configuration already exists"
        return 0
    fi
    
    cat > "${DR_CONFIG_FILE}" << 'EOF'
# Disaster Recovery Configuration

# Primary Splunk installation
PRIMARY_SPLUNK_HOME="/opt/splunk"
PRIMARY_DATA_DIR="/opt/splunk/var/lib/splunk"

# Backup locations
PRIMARY_BACKUP_DIR="/opt/splunk/backups"
REMOTE_BACKUP_DIR="/mnt/remote_backups"

# Recovery target
RECOVERY_SPLUNK_HOME="/opt/splunk"
RECOVERY_DATA_DIR="/opt/splunk/var/lib/splunk"

# Network settings
INDEXER_DISCOVERY_PASS="changeme"
CLUSTER_MASTER_URI="https://cluster-master:8089"
SEARCH_HEAD_CLUSTER_PASS="changeme"

# Recovery options
RECOVERY_POINT_OBJECTIVE_HOURS=24
RECOVERY_TIME_OBJECTIVE_HOURS=4
PARTIAL_RECOVERY_ENABLED=true

# Notification settings
DR_NOTIFICATION_EMAIL="admin@example.com"
DR_SLACK_WEBHOOK=""
EOF
    
    log_info "Created default DR configuration"
}

execute_full_disaster_recovery() {
    local recovery_mode="${1:-full}"
    local backup_source="${2:-latest}"
    
    log_info "Starting disaster recovery: mode=${recovery_mode}, source=${backup_source}"
    
    # Load DR configuration
    source "${DR_CONFIG_FILE}"
    
    # Pre-recovery checks
    perform_pre_recovery_checks "${recovery_mode}"
    
    # Stop all Splunk services
    stop_all_splunk_services
    
    # Backup current state (if any)
    backup_current_state
    
    # Execute recovery based on mode
    case "${recovery_mode}" in
        "full")
            execute_full_recovery "${backup_source}"
            ;;
        "config-only")
            execute_config_recovery "${backup_source}"
            ;;
        "partial")
            execute_partial_recovery "${backup_source}"
            ;;
        *)
            error_exit "Invalid recovery mode: ${recovery_mode}"
            ;;
    esac
    
    # Post-recovery validation
    perform_post_recovery_validation
    
    # Start Splunk services
    start_splunk_services
    
    # Send recovery notification
    send_dr_notification "SUCCESS" "Disaster recovery completed successfully"
    
    log_success "Disaster recovery completed"
}

perform_pre_recovery_checks() {
    local recovery_mode="$1"
    
    log_info "Performing pre-recovery checks..."
    
    # Check available disk space
    local available_space
    available_space=$(df "${RECOVERY_DATA_DIR}" | awk 'NR==2 {print $4}')
    local required_space=10485760  # 10GB minimum
    
    if [[ ${available_space} -lt ${required_space} ]]; then
        error_exit "Insufficient disk space for recovery"
    fi
    
    # Check if backup source exists
    if [[ "${2}" != "latest" ]] && [[ ! -f "${2}" ]]; then
        error_exit "Backup file not found: ${2}"
    fi
    
    # Verify network connectivity (if cluster recovery)
    if [[ "${recovery_mode}" == "full" ]]; then
        verify_cluster_connectivity
    fi
    
    log_success "Pre-recovery checks passed"
}

execute_full_recovery() {
    local backup_source="$1"
    
    log_info "Executing full disaster recovery..."
    
    # Find latest backup if not specified
    if [[ "${backup_source}" == "latest" ]]; then
        backup_source=$(find "${PRIMARY_BACKUP_DIR}" -name "*.tar.gz" -type f -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2)
        
        if [[ -z "${backup_source}" ]]; then
            error_exit "No backup files found for recovery"
        fi
        
        log_info "Using latest backup: ${backup_source}"
    fi
    
    # Execute full restore
    "${SCRIPT_DIR}/backup_manager.sh" restore "${backup_source}" full
    
    # Additional cluster-specific recovery steps
    recover_cluster_configuration
    recover_indexer_cluster
    recover_search_head_cluster
    
    log_success "Full recovery execution completed"
}

execute_config_recovery() {
    local backup_source="$1"
    
    log_info "Executing configuration-only recovery..."
    
    # Find latest config backup
    if [[ "${backup_source}" == "latest" ]]; then
        backup_source=$(find "${PRIMARY_BACKUP_DIR}" -name "*config*.tar.gz" -type f -printf '%T@ %p\n' | sort -nr | head -1 | cut -d' ' -f2)
    fi
    
    # Execute config restore
    "${SCRIPT_DIR}/backup_manager.sh" restore "${backup_source}" config-only
    
    log_success "Configuration recovery completed"
}

execute_partial_recovery() {
    local backup_source="$1"
    
    log_info "Executing partial recovery..."
    
    # Interactive recovery selection
    select_recovery_components "${backup_source}"
    
    log_success "Partial recovery completed"
}

recover_cluster_configuration() {
    log_info "Recovering cluster configuration..."
    
    # Update server.conf with current IP/hostname
    local current_hostname
    current_hostname=$(hostname)
    
    # Update cluster configuration files
    update_cluster_configs "${current_hostname}"
    
    log_success "Cluster configuration recovery completed"
}

recover_indexer_cluster() {
    log_info "Recovering indexer cluster..."
    
    # Wait for cluster master
    wait_for_cluster_master
    
    # Re-join indexer cluster
    rejoin_indexer_cluster
    
    log_success "Indexer cluster recovery completed"
}

recover_search_head_cluster() {
    log_info "Recovering search head cluster..."
    
    # Re-initialize search head cluster
    reinitialize_search_head_cluster
    
    log_success "Search head cluster recovery completed"
}

perform_post_recovery_validation() {
    log_info "Performing post-recovery validation..."
    
    # Validate Splunk installation
    if ! splunk version >/dev/null 2>&1; then
        error_exit "Splunk installation validation failed"
    fi
    
    # Validate configuration files
    validate_configuration_files
    
    # Test basic functionality
    test_basic_functionality
    
    log_success "Post-recovery validation passed"
}

validate_configuration_files() {
    local config_files=(
        "etc/system/local/server.conf"
        "etc/system/local/inputs.conf"
        "etc/system/local/outputs.conf"
    )
    
    for config_file in "${config_files[@]}"; do
        local file_path="${RECOVERY_SPLUNK_HOME}/${config_file}"
        if [[ -f "${file_path}" ]]; then
            # Basic syntax validation
            if ! splunk btool server list --debug 2>&1 | grep -q "ERROR"; then
                log_info "Configuration file validated: ${config_file}"
            else
                log_error "Configuration file has errors: ${config_file}"
            fi
        fi
    done
}

test_basic_functionality() {
    log_info "Testing basic Splunk functionality..."
    
    # Test search functionality
    local search_result
    search_result=$(splunk search "| gentimes start=-1h | head 1" -auth admin:changeme 2>/dev/null || echo "FAILED")
    
    if [[ "${search_result}" != "FAILED" ]]; then
        log_success "Basic search functionality test passed"
    else
        log_warning "Basic search functionality test failed"
    fi
}

create_recovery_procedures() {
    local procedures_file="${SCRIPT_DIR}/RECOVERY_PROCEDURES.md"
    
    cat > "${procedures_file}" << 'EOF'
# Splunk Disaster Recovery Procedures

## Emergency Contacts
- Primary Administrator: [Contact Information]
- Secondary Administrator: [Contact Information]
- Infrastructure Team: [Contact Information]

## Recovery Procedures

### 1. Assess the Situation
- Determine the scope of the disaster
- Identify affected systems
- Estimate recovery time requirements

### 2. Initialize Recovery
```bash
./disaster_recovery.sh init
```

### 3. Execute Recovery
```bash
# Full recovery from latest backup
./disaster_recovery.sh recover full latest

# Configuration-only recovery
./disaster_recovery.sh recover config-only latest

# Recovery from specific backup
./disaster_recovery.sh recover full /path/to/backup.tar.gz
```

### 4. Validate Recovery
```bash
./disaster_recovery.sh validate
```

### 5. Post-Recovery Steps
- Update DNS records if necessary
- Notify stakeholders
- Update monitoring systems
- Document lessons learned

## Recovery Time Objectives
- Critical systems: 4 hours
- Non-critical systems: 24 hours

## Recovery Point Objectives
- Configuration data: 24 hours
- Index data: Based on backup schedule
EOF
    
    log_info "Recovery procedures documentation created"
}

send_dr_notification() {
    local status="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Log notification
    echo "[${timestamp}] DR_NOTIFICATION: ${status} - ${message}" >> "${DR_LOG_FILE}"
    
    # Send notifications (similar to backup notifications but with DR context)
    if [[ -n "${DR_NOTIFICATION_EMAIL:-}" ]]; then
        echo "Disaster Recovery Notification: ${status} - ${message}" | \
            mail -s "[URGENT] Splunk Disaster Recovery: ${status}" "${DR_NOTIFICATION_EMAIL}"
    fi
}

main() {
    local action="${1:-}"
    
    case "${action}" in
        "init")
            initialize_disaster_recovery
            ;;
        "recover")
            local recovery_mode="${2:-full}"
            local backup_source="${3:-latest}"
            execute_full_disaster_recovery "${recovery_mode}" "${backup_source}"
            ;;
        "validate")
            perform_post_recovery_validation
            ;;
        "test")
            test_basic_functionality
            ;;
        *)
            cat << EOF
Usage: $0 {init|recover|validate|test}

Commands:
    init                            Initialize disaster recovery system
    recover <mode> [backup]         Execute disaster recovery
    validate                        Validate recovery completion
    test                           Test basic functionality

Recovery Modes:
    full                           Full cluster recovery
    config-only                    Configuration-only recovery
    partial                        Interactive partial recovery

Examples:
    $0 init
    $0 recover full latest
    $0 recover config-only /backups/config_backup.tar.gz
    $0 validate
EOF
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_entrypoint main "$@"
fi

# ============================= Script Configuration ===========================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load standardized error handling first
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Failed to load error handling library" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging "disaster_recovery"

# Set error handling


