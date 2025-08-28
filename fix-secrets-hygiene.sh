#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# fix-secrets-hygiene.sh - Apply secrets hygiene to all entrypoint scripts


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/secrets-hygiene.sh"

main() {
    log_message INFO "Starting secrets hygiene fixes..."
    
    log_message INFO "Applying secrets hygiene fixes to all entrypoint scripts..."
    
    # Initialize secure secrets directory
    init_secrets_directory "${SCRIPT_DIR}/secrets"
    
    # Fix remaining scripts with hardcoded passwords
    fix_hardcoded_passwords
    
    # Update credential generation scripts
    update_credential_scripts
    
    # Fix test scripts that leak credentials
    fix_test_credential_leaks
    
    # Verify all credential files have secure permissions
    verify_credential_file_permissions
    
    log_message SUCCESS "Secrets hygiene fixes applied successfully"
}

fix_hardcoded_passwords() {
    log_message INFO "Removing hardcoded passwords from scripts..."
    
    # Fix test scripts with hardcoded credentials
    local test_files=(
        "test-simple-creds.sh"
        "test-phase2-complete.sh"
        "monitoring/collectors/splunk_metrics.sh"
    )
    
    for file in "${test_files[@]}"; do
        local file_path="${SCRIPT_DIR}/$file"
        if [[ -f "$file_path" ]]; then
            # Replace password echoing with redacted messages
            if grep -q "echo.*password.*=" "$file_path" 2>/dev/null; then
                log_message INFO "Fixing password echoing in: $file"
                sed -i.bak 's/echo.*password.*=.*/log_secure INFO "Password loaded from credentials file"/gi' "$file_path"
            fi
            
            # Replace direct password/credential echoing
            if grep -q "echo.*SPLUNK_PASSWORD" "$file_path" 2>/dev/null; then
                log_message INFO "Fixing SPLUNK_PASSWORD echoing in: $file"
                sed -i.bak 's/echo.*SPLUNK_PASSWORD.*/log_secure INFO "Splunk credentials verified"/g' "$file_path"
            fi
        fi
    done
}

update_credential_scripts() {
    log_message INFO "Updating credential generation scripts..."
    
    # Update generate-credentials.sh to use secrets hygiene
    local creds_script="${SCRIPT_DIR}/generate-credentials.sh"
    if [[ -f "$creds_script" ]]; then
        # Add secrets hygiene source if not present
        if ! grep -q "secrets-hygiene.sh" "$creds_script"; then
            log_message INFO "Adding secrets hygiene to generate-credentials.sh"
            # Insert after existing source statements
            sed -i.bak '/source.*error-handling.sh/a source "${SCRIPT_DIR}/lib/secrets-hygiene.sh"' "$creds_script"
        fi
    fi
    
    # Update deploy scripts to use secure writing
    local deploy_scripts=(
        "deploy_fixed.sh"
        "deploy-main.sh" 
        "deploy-clean.sh"
    )
    
    for script in "${deploy_scripts[@]}"; do
        local script_path="${SCRIPT_DIR}/$script"
        if [[ -f "$script_path" ]]; then
            # Replace insecure password file writing
            if grep -q 'echo.*SPLUNK_PASSWORD.*>' "$script_path"; then
                log_message INFO "Fixing password file writing in: $script"
                sed -i.bak 's/echo.*SPLUNK_PASSWORD.*>/write_secure_file "$CREDS_PASS_FILE" "$SPLUNK_PASSWORD" 600/g' "$script_path"
            fi
        fi
    done
}

fix_test_credential_leaks() {
    log_message INFO "Fixing credential leaks in test scripts..."
    
    # Find all test scripts that might leak credentials
    local test_scripts
    mapfile -t test_scripts < <(find "${SCRIPT_DIR}" -name "*test*.sh" -type f 2>/dev/null || true)
    
    for test_script in "${test_scripts[@]}"; do
        if [[ -f "$test_script" ]]; then
            # Replace direct password echoing with secure logging
            if grep -q "echo.*password.*:" "$test_script" 2>/dev/null; then
                log_message INFO "Fixing password echoing in: $(basename "$test_script")"
                sed -i.bak "s/echo.*password.*:/log_secure INFO \"Password test completed\":/gi" "$test_script"
            fi
            
            # Replace credential variable echoing
            if grep -q "echo.*Got:.*pass=" "$test_script" 2>/dev/null; then
                log_message INFO "Fixing credential echoing in: $(basename "$test_script")"
                sed -i.bak 's/echo.*Got:.*pass=.*/log_secure INFO "Credentials verified successfully"/g' "$test_script"
            fi
        fi
    done
}

verify_credential_file_permissions() {
    log_message INFO "Verifying secure permissions on credential files..."
    
    local credential_patterns=(
        "*.pass"
        "*.creds"
        "*.key"
        "*.pem"
        ".env"
        "*.env"
    )
    
    for pattern in "${credential_patterns[@]}"; do
        while IFS= read -r -d '' file; do
            if [[ -f "$file" ]]; then
                local current_perms
                current_perms=$(stat -c "%a" "$file" 2>/dev/null || echo "unknown")
                
                # Check if permissions are too permissive
                if [[ "$current_perms" != "600" && "$current_perms" != "640" ]]; then
                    log_message WARN "Fixing insecure permissions on: $file ($current_perms -> 600)"
                    chmod 600 "$file" || log_message ERROR "Failed to fix permissions on: $file"
                else
                    log_message DEBUG "Verified secure permissions on: $file ($current_perms)"
                fi
            fi
        done < <(find "${SCRIPT_DIR}" -name "$pattern" -type f -print0 2>/dev/null || true)
    done
}

# Only run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
