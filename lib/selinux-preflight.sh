#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# lib/selinux-preflight.sh - SELinux preflight checks for Docker/Podman compose files

# Prevent multiple sourcing
[[ -n "${SELINUX_PREFLIGHT_LIB_SOURCED:-}" ]] && return 0
readonly SELINUX_PREFLIGHT_LIB_SOURCED=1

# Source required libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/error-handling.sh"

# =============================================================================
# SELINUX DETECTION AND STATUS
# =============================================================================

# Check SELinux status and availability
# Returns: 0=enforcing, 1=permissive, 2=disabled, 3=not_available
get_selinux_status() {
    if ! command -v getenforce >/dev/null 2>&1; then
        log_message DEBUG "SELinux tools not available"
        return 3
    fi
    
    local status
    status=$(getenforce 2>/dev/null || echo "Unknown")
    
    case "${status,,}" in
        enforcing)
            log_message DEBUG "SELinux status: Enforcing"
            return 0
            ;;
        permissive)
            log_message DEBUG "SELinux status: Permissive"
            return 1
            ;;
        disabled)
            log_message DEBUG "SELinux status: Disabled"
            return 2
            ;;
        *)
            log_message DEBUG "SELinux status: Unknown ($status)"
            return 3
            ;;
    esac
}

# Check if SELinux is enforcing
is_selinux_enforcing() {
    get_selinux_status
    return $?
}

# =============================================================================
# RUNTIME DETECTION
# =============================================================================

# Detect container runtime (Docker vs Podman)
detect_container_runtime() {
    local runtime=""
    
    # Check for docker-compose or docker compose
    if command -v docker-compose >/dev/null 2>&1; then
        runtime="docker"
    elif docker compose version >/dev/null 2>&1; then
        runtime="docker"
    elif command -v podman-compose >/dev/null 2>&1; then
        runtime="podman"
    elif command -v podman >/dev/null 2>&1; then
        runtime="podman"
    else
        log_message WARN "No container runtime detected"
        return 1
    fi
    
    log_message DEBUG "Detected container runtime: $runtime"
    echo "$runtime"
    return 0
}

# =============================================================================
# COMPOSE FILE VOLUME ANALYSIS
# =============================================================================

# Extract volume mounts from compose file
# Usage: extract_volume_mounts <compose_file>
extract_volume_mounts() {
    local compose_file="$1"
    
    if [[ ! -f "$compose_file" ]]; then
        log_message ERROR "Compose file not found: $compose_file"
        return 1
    fi
    
    # Use awk to extract volume mount lines, handling various YAML formats
    awk '
    /^[[:space:]]*volumes:[[:space:]]*$/ { in_volumes = 1; next }
    /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_-]*:[[:space:]]*$/ && in_volumes { in_volumes = 0 }
    /^[[:space:]]*-[[:space:]]*/ && in_volumes {
        # Extract volume mount line
        gsub(/^[[:space:]]*-[[:space:]]*/, "")
        gsub(/[[:space:]]*$/, "")
        if ($0 ~ /^[.\/].*:/) {
            print $0
        }
    }
    ' "$compose_file"
}

# Check if a volume mount has SELinux context flags
# Usage: has_selinux_flags <mount_spec>
has_selinux_flags() {
    local mount_spec="$1"
    
    # Check for :Z or :z flags (case insensitive)
    if [[ "$mount_spec" =~ :[Zz]([[:space:]]*$|,) ]]; then
        return 0
    fi
    
    return 1
}

# Parse volume mount specification
# Usage: parse_volume_mount <mount_spec>
# Returns: host_path:container_path:flags
parse_volume_mount() {
    local mount_spec="$1"
    
    # Split on colons, being careful about Windows paths
    local parts
    IFS=':' read -ra parts <<< "$mount_spec"
    
    local host_path="${parts[0]}"
    local container_path="${parts[1]:-}"
    local flags="${parts[2]:-}"
    
    # Handle additional flag parts
    if [[ ${#parts[@]} -gt 3 ]]; then
        for ((i=3; i<${#parts[@]}; i++)); do
            flags="${flags}:${parts[i]}"
        done
    fi
    
    echo "HOST_PATH=$host_path"
    echo "CONTAINER_PATH=$container_path"
    echo "FLAGS=$flags"
}

# =============================================================================
# SELINUX VALIDATION
# =============================================================================

# Validate volume mount for SELinux compatibility
# Usage: validate_volume_mount <mount_spec> <runtime>
validate_volume_mount() {
    local mount_spec="$1"
    local runtime="$2"
    
    # Parse the mount specification
    local mount_info
    mount_info=$(parse_volume_mount "$mount_spec")
    eval "$mount_info"
    
    # Skip if not a bind mount (no host path starting with . or /)
    if [[ ! "$HOST_PATH" =~ ^[./] ]]; then
        log_message DEBUG "Skipping non-bind mount: $mount_spec"
        return 0
    fi
    
    # For Docker with SELinux enforcing, check for SELinux flags
    if [[ "$runtime" == "docker" ]]; then
        if ! has_selinux_flags "$mount_spec"; then
            log_message ERROR "SELinux violation: Docker bind mount missing :Z or :z flag"
            log_message ERROR "Mount: $mount_spec"
            log_message ERROR "Host path: $HOST_PATH"
            log_message ERROR "Container path: $CONTAINER_PATH"
            log_message ERROR ""
            log_message ERROR "SOLUTION: Add SELinux context flag to fix this:"
            log_message ERROR "  Current:  $mount_spec"
            if [[ -n "$FLAGS" ]]; then
                log_message ERROR "  Fixed:    $HOST_PATH:$CONTAINER_PATH:$FLAGS:Z"
            else
                log_message ERROR "  Fixed:    $HOST_PATH:$CONTAINER_PATH:Z"
            fi
            log_message ERROR ""
            log_message ERROR "Choose the appropriate flag:"
            log_message ERROR "  :Z  - Private unshared label (recommended for exclusive access)"
            log_message ERROR "  :z  - Shared label (for sharing between containers)"
            return 1
        else
            log_message DEBUG "SELinux flags found in mount: $mount_spec"
        fi
    else
        # Podman typically handles SELinux automatically
        log_message DEBUG "Podman mount (auto SELinux): $mount_spec"
    fi
    
    return 0
}

# =============================================================================
# PREFLIGHT CHECK FUNCTIONS
# =============================================================================

# Comprehensive SELinux preflight check
# Usage: selinux_preflight_check <compose_file>
selinux_preflight_check() {
    local compose_file="$1"
    
    if [[ -z "$compose_file" ]]; then
        log_message ERROR "selinux_preflight_check requires compose file path"
        return 1
    fi
    
    log_message INFO "Running SELinux preflight check for: $compose_file"
    
    # Check if SELinux is enforcing
    if ! is_selinux_enforcing; then
        local status_code=$?
        case $status_code in
            1) log_message INFO "SELinux is permissive - volume mount check skipped" ;;
            2) log_message INFO "SELinux is disabled - volume mount check skipped" ;;
            3) log_message INFO "SELinux not available - volume mount check skipped" ;;
        esac
        return 0
    fi
    
    log_message INFO "SELinux is enforcing - validating volume mounts"
    
    # Detect container runtime
    local runtime
    runtime=$(detect_container_runtime) || {
        log_message ERROR "Failed to detect container runtime"
        return 1
    }
    
    # Extract and validate volume mounts
    local mount_errors=0
    local mounts
    mounts=$(extract_volume_mounts "$compose_file") || {
        log_message ERROR "Failed to extract volume mounts from: $compose_file"
        return 1
    }
    
    if [[ -z "$mounts" ]]; then
        log_message INFO "No bind mounts found in compose file"
        return 0
    fi
    
    log_message INFO "Validating bind mounts for SELinux compatibility..."
    
    while IFS= read -r mount; do
        [[ -n "$mount" ]] || continue
        
        log_message DEBUG "Checking mount: $mount"
        
        if ! validate_volume_mount "$mount" "$runtime"; then
            ((mount_errors++))
        fi
    done <<< "$mounts"
    
    if [[ $mount_errors -gt 0 ]]; then
        log_message ERROR ""
        log_message ERROR "SELinux preflight check FAILED with $mount_errors volume mount error(s)"
        log_message ERROR ""
        log_message ERROR "When SELinux is enforcing, Docker bind mounts require context labels."
        log_message ERROR "Without proper labels, containers will fail with permission denied errors."
        log_message ERROR ""
        log_message ERROR "Fix the volume mounts above and re-run the preflight check."
        return 1
    else
        log_message SUCCESS "SELinux preflight check PASSED - all volume mounts are properly configured"
        return 0
    fi
}

# Batch check multiple compose files
# Usage: selinux_preflight_check_batch <file1> [file2] [file3]...
selinux_preflight_check_batch() {
    local files=("$@")
    local total_errors=0
    
    if [[ ${#files[@]} -eq 0 ]]; then
        log_message ERROR "selinux_preflight_check_batch requires at least one compose file"
        return 1
    fi
    
    log_message INFO "Running SELinux preflight check on ${#files[@]} compose file(s)"
    
    for compose_file in "${files[@]}"; do
        log_message INFO "Checking: $compose_file"
        
        if [[ ! -f "$compose_file" ]]; then
            log_message ERROR "Compose file not found: $compose_file"
            ((total_errors++))
            continue
        fi
        
        if ! selinux_preflight_check "$compose_file"; then
            ((total_errors++))
        fi
        
        echo # Add spacing between files
    done
    
    if [[ $total_errors -gt 0 ]]; then
        log_message ERROR "SELinux preflight batch check FAILED - $total_errors file(s) with errors"
        return 1
    else
        log_message SUCCESS "SELinux preflight batch check PASSED - all files validated"
        return 0
    fi
}

# =============================================================================
# AUTOMATED FIXES
# =============================================================================

# Suggest or apply fixes for SELinux volume mount issues
# Usage: fix_selinux_volume_mounts <compose_file> [--apply]
fix_selinux_volume_mounts() {
    local compose_file="$1"
    local apply_fixes="${2:-}"
    
    if [[ ! -f "$compose_file" ]]; then
        log_message ERROR "Compose file not found: $compose_file"
        return 1
    fi
    
    # Only proceed if SELinux is enforcing
    if ! is_selinux_enforcing; then
        log_message INFO "SELinux not enforcing - no fixes needed"
        return 0
    fi
    
    local runtime
    runtime=$(detect_container_runtime) || {
        log_message ERROR "Failed to detect container runtime"
        return 1
    }
    
    # Only fix Docker mounts (Podman handles SELinux automatically)
    if [[ "$runtime" != "docker" ]]; then
        log_message INFO "Podman runtime detected - SELinux handled automatically"
        return 0
    fi
    
    log_message INFO "Analyzing Docker volume mounts for SELinux fixes..."
    
    local mounts
    mounts=$(extract_volume_mounts "$compose_file")
    
    if [[ -z "$mounts" ]]; then
        log_message INFO "No bind mounts found"
        return 0
    fi
    
    local fixes_needed=0
    local temp_file
    
    if [[ "$apply_fixes" == "--apply" ]]; then
        temp_file=$(mktemp "${compose_file}.selinux.XXXXXX")
        cp "$compose_file" "$temp_file"
    fi
    
    while IFS= read -r mount; do
        [[ -n "$mount" ]] || continue
        
        local mount_info
        mount_info=$(parse_volume_mount "$mount")
        eval "$mount_info"
        
        # Skip non-bind mounts
        [[ "$HOST_PATH" =~ ^[./] ]] || continue
        
        if ! has_selinux_flags "$mount"; then
            ((fixes_needed++))
            
            local fixed_mount
            if [[ -n "$FLAGS" ]]; then
                fixed_mount="$HOST_PATH:$CONTAINER_PATH:$FLAGS:Z"
            else
                fixed_mount="$HOST_PATH:$CONTAINER_PATH:Z"
            fi
            
            log_message INFO "Fix needed for mount: $mount"
            log_message INFO "  Suggested fix: $fixed_mount"
            
            if [[ "$apply_fixes" == "--apply" ]]; then
                # Escape special characters for sed
                local escaped_old escaped_new
                escaped_old=$(printf '%s\n' "$mount" | sed 's/[[\.*^$()+?{|]/\\&/g')
                escaped_new=$(printf '%s\n' "$fixed_mount" | sed 's/[[\.*^$()+?{|]/\\&/g')
                
                sed -i "s|$escaped_old|$escaped_new|g" "$temp_file"
                log_message INFO "  Applied fix to temporary file"
            fi
        fi
    done <<< "$mounts"
    
    if [[ $fixes_needed -eq 0 ]]; then
        log_message SUCCESS "No SELinux volume mount fixes needed"
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
        return 0
    fi
    
    if [[ "$apply_fixes" == "--apply" ]]; then
        # Create backup and apply fixes
        local backup_file="${compose_file}.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$compose_file" "$backup_file"
        mv "$temp_file" "$compose_file"
        
        log_message SUCCESS "Applied $fixes_needed SELinux volume mount fix(es)"
        log_message INFO "Original file backed up to: $backup_file"
        log_message INFO "Updated file: $compose_file"
    else
        log_message INFO "$fixes_needed volume mount(s) need SELinux fixes"
        log_message INFO "Run with --apply flag to automatically apply fixes"
        [[ -n "$temp_file" ]] && rm -f "$temp_file"
    fi
    
    return 0
}

# =============================================================================
# VALIDATION INTEGRATION
# =============================================================================

# Integration point for compose validation system
# Usage: validate_selinux_compatibility <compose_file>
validate_selinux_compatibility() {
    local compose_file="$1"
    
    if [[ -z "$compose_file" ]]; then
        log_message ERROR "validate_selinux_compatibility requires compose file path"
        return 1
    fi
    
    # Run the preflight check
    selinux_preflight_check "$compose_file"
}

# Export functions for use in other scripts
export -f get_selinux_status is_selinux_enforcing detect_container_runtime
export -f extract_volume_mounts has_selinux_flags parse_volume_mount
export -f validate_volume_mount selinux_preflight_check selinux_preflight_check_batch
export -f fix_selinux_volume_mounts validate_selinux_compatibility
