#!/bin/bash
# generate-credentials.sh - Complete credential generation with comprehensive error handling
# Securely generates and stores credentials for Splunk cluster

# Source error handling module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/error-handling.sh" || {
    echo "ERROR: Cannot load error handling module from lib/error-handling.sh" >&2
    exit 1
}

# Define fallback functions if not loaded from error-handling.sh
if ! type log_message &>/dev/null; then
  log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        ERROR)
            echo -e "\033[0;31m[ERROR]\033[0m $message" >&2
            ;;
        WARNING)
            echo -e "\033[1;33m[WARN ]\033[0m $message" >&2
            ;;
        INFO)
            echo -e "\033[0;34m[INFO ]\033[0m $message"
            ;;
        SUCCESS)
            echo -e "\033[0;32m[OK   ]\033[0m $message"
            ;;
        DEBUG)
            if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
                echo -e "\033[1;33m[DEBUG]\033[0m $message" >&2
            fi
            ;;
        *)
            echo "$message"
            ;;
    esac
  }
fi

if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Fallback initialization - just return success
    return 0
  }
fi

if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Fallback cleanup registration - just return success
    return 0
  }
fi

if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code="$1"
    local error_message="$2"
    
    # Handle case where first argument might be the message
    if [[ "$error_code" =~ ^[0-9]+$ ]]; then
      # First argument is numeric (error code)
      log_message ERROR "${error_message:-Unknown error}"
      exit "$error_code"
    else
      # First argument is the message
      log_message ERROR "$error_code"
      exit 1
    fi
  }
fi

if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    # Basic path validation - check if path is safe
    if [[ "$path" =~ \.\. ]] || [[ "$path" =~ ^/ ]] && [[ "$path" != "${SCRIPT_DIR}"* ]]; then
      return 1
    fi
    return 0
  }
fi

# Initialize error handling
init_error_handling

# Configuration
readonly CREDS_DIR="${SCRIPT_DIR}/credentials"
readonly MIN_PASSWORD_LENGTH=8
readonly MAX_PASSWORD_LENGTH=128
readonly MIN_USERNAME_LENGTH=3
readonly MAX_USERNAME_LENGTH=32
readonly DEFAULT_USERNAME="admin"
readonly CERT_VALIDITY_DAYS=365
readonly KEY_SIZE=2048
readonly MIN_CERT_DAYS=1
readonly MAX_CERT_DAYS=3650

# Password complexity requirements
readonly REQUIRE_UPPERCASE=true
readonly REQUIRE_LOWERCASE=true
readonly REQUIRE_NUMBERS=true
readonly REQUIRE_SPECIAL=true
readonly SPECIAL_CHARS='!@#$%^&*()_+-=[]{}|;:,.<>?'

# Global variables
SPLUNK_USER=""
SPLUNK_PASSWORD=""
GENERATE_CERTS=true
FORCE_REGENERATE=false
INTERACTIVE=true
VALIDATE_ONLY=false
EXPORT_ENV=false

# Files to generate
declare -A CREDENTIAL_FILES=(
    ["splunk_admin_user"]="Splunk admin username"
    ["splunk_admin_password"]="Splunk admin password"
    ["splunk_secret"]="Splunk secret key"
    ["cluster_secret"]="Cluster secret key"
    ["indexer_discovery_secret"]="Indexer discovery secret"
    ["shc_secret"]="Search head cluster secret"
)

# Cleanup function
cleanup_credentials() {
    log_message INFO "Cleaning up credential generation resources..."
    
    # Remove temporary files
    rm -f "${CREDS_DIR}/.tmp_*" 2>/dev/null
    
    # Secure permissions on credential directory
    chmod 700 "$CREDS_DIR" 2>/dev/null || true
}

# Usage function
usage() {
    cat << EOF
Usage: $0 [options]

Generate secure credentials for Splunk cluster deployment.

Options:
    --user USERNAME         Splunk admin username (default: admin)
    --password PASSWORD     Splunk admin password (will prompt if not provided)
    --no-certs             Skip SSL certificate generation
    --force                Force regeneration of existing credentials
    --non-interactive      Run without prompts (requires --password)
    --validate-only        Validate existing credentials without generating
    --export-env           Export credentials as environment variables
    --cert-days DAYS       Certificate validity period (1-3650, default: 365)
    --key-size SIZE        RSA key size (1024, 2048, 4096, default: 2048)
    --help                 Display this help message

Password Requirements:
    - Minimum $MIN_PASSWORD_LENGTH characters
    - Must contain uppercase and lowercase letters
    - Must contain numbers
    - Must contain special characters
    - Cannot contain username

Examples:
    $0
    $0 --user splunkadmin
    $0 --user admin --password 'SecureP@ss123!' --no-certs
    $0 --validate-only

EOF
    exit 0
}

# Parse command line arguments
parse_arguments() {
    log_message INFO "Parsing credential generation arguments"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                SPLUNK_USER="$2"
                shift 2
                ;;
            --password)
                SPLUNK_PASSWORD="$2"
                shift 2
                ;;
            --no-certs)
                GENERATE_CERTS=false
                shift
                ;;
            --force)
                FORCE_REGENERATE=true
                shift
                ;;
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
            --validate-only)
                VALIDATE_ONLY=true
                shift
                ;;
            --export-env)
                EXPORT_ENV=true
                shift
                ;;
            --cert-days)
                CERT_VALIDITY_DAYS="$2"
                validate_timeout "$CERT_VALIDITY_DAYS" "$MIN_CERT_DAYS" "$MAX_CERT_DAYS"
                shift 2
                ;;
            --key-size)
                KEY_SIZE="$2"
                case "$KEY_SIZE" in
                    1024|2048|4096)
                        # Valid key sizes
                        ;;
                    *)
                        error_exit "Invalid key size: $KEY_SIZE (must be 1024, 2048, or 4096)"
                        ;;
                esac
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
}

# Validate username
validate_username() {
    local username="$1"
    
    log_message DEBUG "Validating username: $username"
    
    # Check if empty
    if [[ -z "$username" ]]; then
        error_exit "Username cannot be empty"
    fi
    
    # Check length
    if [[ ${#username} -lt $MIN_USERNAME_LENGTH ]]; then
        error_exit "Username must be at least $MIN_USERNAME_LENGTH characters long"
    fi
    
    if [[ ${#username} -gt $MAX_USERNAME_LENGTH ]]; then
        error_exit "Username cannot exceed $MAX_USERNAME_LENGTH characters"
    fi
    
    # Check format (alphanumeric, underscore, hyphen)
    if ! [[ "$username" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        error_exit "Username must start with a letter and contain only letters, numbers, underscores, and hyphens"
    fi
    
    # Check for reserved usernames
    local reserved_users=("root" "nobody" "daemon" "bin" "sys" "sync" "games" "man" "lp" "mail" "news" "uucp" "proxy")
    
    for reserved in "${reserved_users[@]}"; do
        if [[ "$username" == "$reserved" ]]; then
            error_exit "Username '$username' is reserved and cannot be used"
        fi
    done
    
    log_message SUCCESS "Username validation passed"
    return 0
}

# Validate password complexity
validate_password() {
    local password="$1"
    local username="${2:-}"
    
    log_message DEBUG "Validating password complexity"
    
    # Check if empty
    if [[ -z "$password" ]]; then
        error_exit "Password cannot be empty"
    fi
    
    # Check length
    if [[ ${#password} -lt $MIN_PASSWORD_LENGTH ]]; then
        error_exit "Password must be at least $MIN_PASSWORD_LENGTH characters long"
    fi
    
    if [[ ${#password} -gt $MAX_PASSWORD_LENGTH ]]; then
        error_exit "Password cannot exceed $MAX_PASSWORD_LENGTH characters"
    fi
    
    # Check for username in password
    if [[ -n "$username" ]] && [[ "${password,,}" == *"${username,,}"* ]]; then
        error_exit "Password cannot contain the username"
    fi
    
    # Check complexity requirements
    local has_upper=false
    local has_lower=false
    local has_number=false
    local has_special=false
    
    if [[ "$password" =~ [A-Z] ]]; then has_upper=true; fi
    if [[ "$password" =~ [a-z] ]]; then has_lower=true; fi
    if [[ "$password" =~ [0-9] ]]; then has_number=true; fi
    if [[ "$password" =~ [\!\@\#\$\%\^\&\*\(\)\_\+\-\=\[\]\{\}\|\;\:\,\.\<\>\?] ]]; then has_special=true; fi
    
    # Validate against requirements
    if [[ "$REQUIRE_UPPERCASE" == "true" ]] && [[ "$has_upper" != "true" ]]; then
        error_exit "Password must contain at least one uppercase letter"
    fi
    
    if [[ "$REQUIRE_LOWERCASE" == "true" ]] && [[ "$has_lower" != "true" ]]; then
        error_exit "Password must contain at least one lowercase letter"
    fi
    
    if [[ "$REQUIRE_NUMBERS" == "true" ]] && [[ "$has_number" != "true" ]]; then
        error_exit "Password must contain at least one number"
    fi
    
    if [[ "$REQUIRE_SPECIAL" == "true" ]] && [[ "$has_special" != "true" ]]; then
        error_exit "Password must contain at least one special character ($SPECIAL_CHARS)"
    fi
    
    # Check for common weak passwords
    check_weak_password "$password"
    
    log_message SUCCESS "Password validation passed"
    return 0
}

# Check for weak passwords
check_weak_password() {
    local password="$1"
    
    # Common weak passwords to check against
    local weak_passwords=(
        "password" "Password1" "Password123" "Admin123" "admin123"
        "12345678" "123456789" "qwerty123" "Qwerty123" "Welcome1"
        "Welcome123" "Splunk123" "splunk123" "changeme" "ChangeMe123"
    )
    
    for weak in "${weak_passwords[@]}"; do
        if [[ "${password,,}" == "${weak,,}" ]]; then
            error_exit "Password is too common. Please choose a stronger password."
        fi
    done
    
    # Check for sequential characters
    if [[ "$password" =~ (012|123|234|345|456|567|678|789|abc|bcd|cde|def) ]]; then
        log_message WARNING "Password contains sequential characters, consider using a stronger password"
    fi
    
    # Check for repeated characters
    if [[ "$password" =~ (.)\1{3,} ]]; then
        log_message WARNING "Password contains repeated characters, consider using a stronger password"
    fi
}

# Generate secure random password
generate_secure_password() {
    local length="${1:-16}"
    
    log_message DEBUG "Generating secure password of length $length"
    
    local password=""
    local chars=""
    
    # Build character set based on requirements
    [[ "$REQUIRE_UPPERCASE" == "true" ]] && chars="${chars}ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    [[ "$REQUIRE_LOWERCASE" == "true" ]] && chars="${chars}abcdefghijklmnopqrstuvwxyz"
    [[ "$REQUIRE_NUMBERS" == "true" ]] && chars="${chars}0123456789"
    [[ "$REQUIRE_SPECIAL" == "true" ]] && chars="${chars}${SPECIAL_CHARS}"
    
    # Generate password
    while [[ ${#password} -lt $length ]]; do
        password="${password}${chars:RANDOM % ${#chars}:1}"
    done
    
    # Ensure password meets all requirements
    local valid=false
    local attempts=0
    
    while [[ "$valid" != "true" ]] && [[ $attempts -lt 10 ]]; do
        if validate_password "$password" "" 2>/dev/null; then
            valid=true
        else
            # Regenerate if validation fails
            password=""
            while [[ ${#password} -lt $length ]]; do
                password="${password}${chars:RANDOM % ${#chars}:1}"
            done
        fi
        attempts=$((attempts + 1))
    done
    
    if [[ "$valid" != "true" ]]; then
        error_exit "Failed to generate valid password after $attempts attempts"
    fi
    
    echo "$password"
}

# Generate secret key
generate_secret_key() {
    local length="${1:-32}"
    
    log_message DEBUG "Generating secret key of length $length"
    
    # Use /dev/urandom for cryptographically secure random data
    if [[ -r /dev/urandom ]]; then
        tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    else
        # Fallback to openssl if available
        if command -v openssl &>/dev/null; then
            openssl rand -base64 "$length" | tr -d '\n=' | cut -c1-"$length"
        else
            # Last resort: use bash RANDOM
            local key=""
            local chars="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            for i in $(seq 1 "$length"); do
                key="${key}${chars:RANDOM % ${#chars}:1}"
            done
            echo "$key"
        fi
    fi
}

# Create credentials directory with proper permissions
create_credentials_directory() {
    log_message INFO "Creating credentials directory"
    
    # Validate path safety
    validate_safe_path "$CREDS_DIR" "$SCRIPT_DIR"
    
    if [[ -d "$CREDS_DIR" ]]; then
        if [[ "$FORCE_REGENERATE" != "true" ]]; then
            log_message WARNING "Credentials directory already exists"
            
            if [[ "$INTERACTIVE" == "true" ]]; then
                read -p "Overwrite existing credentials? (y/N): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    log_message INFO "Keeping existing credentials"
                    return 1
                fi
            else
                error_exit "Credentials already exist. Use --force to regenerate."
            fi
        fi
        
        # Backup existing credentials
        local backup_dir="${CREDS_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
        log_message INFO "Backing up existing credentials to $backup_dir"
        if ! mv "$CREDS_DIR" "$backup_dir"; then
            error_exit "Failed to backup existing credentials"
        fi
    fi
    
    # Create directory with secure permissions
    if ! mkdir -p "$CREDS_DIR"; then
        enhanced_permission_error "$CREDS_DIR" "create directory" "$(whoami)"
        error_exit "Failed to create credentials directory - enhanced troubleshooting steps provided above"
    fi
    
    if ! chmod 700 "$CREDS_DIR"; then
        enhanced_permission_error "$CREDS_DIR" "set permissions" "$(whoami)"
        error_exit "Failed to set credentials directory permissions - enhanced troubleshooting steps provided above"
    fi
    
    log_message SUCCESS "Credentials directory created"
    return 0
}

# Write credential to file securely
write_credential() {
    local filename="$1"
    local content="$2"
    local description="${3:-Credential}"
    
    local filepath="${CREDS_DIR}/${filename}"
    log_message DEBUG "Writing $description to $filename"

    # Prefer system keyring / secrets manager when available
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local secrets_cli="$script_dir/security/secrets_manager.sh"
    if [[ -x "$secrets_cli" ]]; then
        # Map filename to service/name: use filename as key name and CREDS_DIR basename as service
        local service
        service="splunk" # default service name for now
        # store using secrets manager
        if ! "$secrets_cli" store_credential "$service" "$filename" "$content"; then
            log_message WARNING "Failed to store $description in secrets manager, falling back to file storage"
        else
            log_message SUCCESS "$description saved in secrets manager"
            return 0
        fi
    fi

    # Fallback: write to file securely (temporary file then atomic move)
    local temp_file="${CREDS_DIR}/.tmp_${filename}_$$"
    if ! echo -n "$content" > "$temp_file"; then
        rm -f "$temp_file" 2>/dev/null
        enhanced_permission_error "$temp_file" "write file" "$(whoami)"
        error_exit "Failed to write $description - enhanced troubleshooting steps provided above"
    fi

    # Set secure permissions
    if ! chmod 600 "$temp_file"; then
        rm -f "$temp_file" 2>/dev/null
        enhanced_permission_error "$temp_file" "set file permissions" "$(whoami)"
        error_exit "Failed to set permissions for $description - enhanced troubleshooting steps provided above"
    fi

    # Move to final location
    if ! mv "$temp_file" "$filepath"; then
        rm -f "$temp_file" 2>/dev/null
        enhanced_permission_error "$filepath" "move file" "$(whoami)"
        error_exit "Failed to save $description - enhanced troubleshooting steps provided above"
    fi

    log_message SUCCESS "$description saved"
}

# Generate SSL certificates
generate_ssl_certificates() {
    if [[ "$GENERATE_CERTS" != "true" ]]; then
        log_message INFO "Skipping SSL certificate generation"
        return 0
    fi
    
    log_message INFO "Generating SSL certificates"
    
    # Check for OpenSSL
    if ! command -v openssl &>/dev/null; then
        log_message WARNING "OpenSSL not found, skipping certificate generation"
        return 1
    fi
    
    local cert_dir="${CREDS_DIR}/certs"
    if ! mkdir -p "$cert_dir"; then
        error_exit "Failed to create certificate directory"
    fi
    
    # Generate CA key and certificate
    log_message INFO "Generating CA certificate"
    
    if ! openssl req -new -x509 -days "$CERT_VALIDITY_DAYS" \
        -keyout "${cert_dir}/ca.key" \
        -out "${cert_dir}/ca.crt" \
        -nodes -subj "/C=US/ST=State/L=City/O=EasySplunk/CN=EasySplunk CA" \
        2>/dev/null; then
        error_exit "Failed to generate CA certificate"
    fi
    
    # Generate server key and certificate
    log_message INFO "Generating server certificate"
    
    if ! openssl req -new -nodes \
        -keyout "${cert_dir}/server.key" \
        -out "${cert_dir}/server.csr" \
        -subj "/C=US/ST=State/L=City/O=EasySplunk/CN=*.splunk.local" \
        2>/dev/null; then
        error_exit "Failed to generate server key"
    fi
    
    if ! openssl x509 -req -days "$CERT_VALIDITY_DAYS" \
        -in "${cert_dir}/server.csr" \
        -CA "${cert_dir}/ca.crt" \
        -CAkey "${cert_dir}/ca.key" \
        -CAcreateserial \
        -out "${cert_dir}/server.crt" \
        2>/dev/null; then
        error_exit "Failed to sign server certificate"
    fi
    
    # Create combined certificate for Splunk
    if ! cat "${cert_dir}/server.crt" "${cert_dir}/server.key" > "${cert_dir}/splunk-server.pem"; then
        error_exit "Failed to create combined certificate"
    fi
    
    # Set secure permissions
    chmod 600 "${cert_dir}"/*.key "${cert_dir}"/*.pem 2>/dev/null || \
        log_message WARNING "Could not set permissions on some certificate files"
    chmod 644 "${cert_dir}"/*.crt 2>/dev/null || \
        log_message WARNING "Could not set permissions on some certificate files"
    
    log_message SUCCESS "SSL certificates generated"
}

# Get credentials interactively
get_credentials_interactive() {
    if [[ "$INTERACTIVE" != "true" ]]; then
        return 0
    fi
    
    log_message INFO "Getting credentials interactively"
    
    # Get username if not provided
    if [[ -z "$SPLUNK_USER" ]]; then
        read -p "Enter Splunk admin username (default: $DEFAULT_USERNAME): " SPLUNK_USER
        SPLUNK_USER="${SPLUNK_USER:-$DEFAULT_USERNAME}"
    fi
    
    # Get password if not provided
    if [[ -z "$SPLUNK_PASSWORD" ]]; then
        echo "Password Requirements:"
        echo "  - Minimum $MIN_PASSWORD_LENGTH characters"
        echo "  - Must contain uppercase and lowercase letters"
        echo "  - Must contain numbers"
        echo "  - Must contain special characters"
        echo ""
        
        local password_valid=false
        local attempts=0
        
        while [[ "$password_valid" != "true" ]] && [[ $attempts -lt 3 ]]; do
            read -s -p "Enter Splunk admin password: " SPLUNK_PASSWORD
            echo
            
            if [[ -z "$SPLUNK_PASSWORD" ]]; then
                # Offer to generate password
                read -p "Would you like to generate a secure password? (Y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Nn]$ ]]; then
                    SPLUNK_PASSWORD=$(generate_secure_password 16)
                    echo "Generated password: $SPLUNK_PASSWORD"
                    echo "Please save this password securely!"
                    password_valid=true
                fi
            else
                # Confirm password
                read -s -p "Confirm password: " password_confirm
                echo
                
                if [[ "$SPLUNK_PASSWORD" != "$password_confirm" ]]; then
                    echo -e "${RED}Passwords do not match${NC}"
                    attempts=$((attempts + 1))
                    continue
                fi
                
                # Validate password
                if validate_password "$SPLUNK_PASSWORD" "$SPLUNK_USER" 2>/dev/null; then
                    password_valid=true
                else
                    attempts=$((attempts + 1))
                fi
            fi
        done
        
        if [[ "$password_valid" != "true" ]]; then
            error_exit "Failed to get valid password after $attempts attempts"
        fi
    fi
}

# Validate existing credentials
validate_existing_credentials() {
    log_message INFO "Validating existing credentials"
    
    local validation_passed=true
    
    # Check if credentials directory exists
    if [[ ! -d "$CREDS_DIR" ]]; then
        log_message ERROR "Credentials directory not found"
        return 1
    fi
    
    # Check each credential file
    for file in "${!CREDENTIAL_FILES[@]}"; do
        local filepath="${CREDS_DIR}/${file}"
        local description="${CREDENTIAL_FILES[$file]}"
        
        if [[ ! -f "$filepath" ]]; then
            log_message ERROR "Missing: $description ($file)"
            validation_passed=false
        else
            # Check file permissions
            local perms
            if ! perms=$(stat -c %a "$filepath" 2>/dev/null) && \
               ! perms=$(stat -f %A "$filepath" 2>/dev/null); then
                log_message WARNING "Could not check permissions for $file"
                perms="unknown"
            fi
            
            if [[ "$perms" != "600" ]] && [[ "$perms" != "unknown" ]]; then
                log_message WARNING "Incorrect permissions on $file: $perms (should be 600)"
            fi
            
            # Check file content
            if [[ ! -s "$filepath" ]]; then
                log_message ERROR "Empty file: $file"
                validation_passed=false
            fi
        fi
    done
    
    # Validate certificate files if expected
    if [[ "$GENERATE_CERTS" == "true" ]]; then
        local cert_files=("certs/ca.crt" "certs/ca.key" "certs/server.crt" "certs/server.key")
        
        for cert_file in "${cert_files[@]}"; do
            if [[ ! -f "${CREDS_DIR}/${cert_file}" ]]; then
                log_message WARNING "Missing certificate: $cert_file"
            fi
        done
    fi
    
    # Load and validate username/password
    if [[ -f "${CREDS_DIR}/splunk_admin_user" ]] && [[ -f "${CREDS_DIR}/splunk_admin_password" ]]; then
        local stored_user
        local stored_pass
        
        if ! stored_user=$(cat "${CREDS_DIR}/splunk_admin_user" 2>/dev/null); then
            log_message ERROR "Failed to read stored username"
            validation_passed=false
        elif ! validate_username "$stored_user" 2>/dev/null; then
            log_message ERROR "Invalid stored username"
            validation_passed=false
        fi
        
        if ! stored_pass=$(cat "${CREDS_DIR}/splunk_admin_password" 2>/dev/null); then
            log_message ERROR "Failed to read stored password"
            validation_passed=false
        elif ! validate_password "$stored_pass" "$stored_user" 2>/dev/null; then
            log_message ERROR "Invalid stored password"
            validation_passed=false
        fi
    fi
    
    if [[ "$validation_passed" == "true" ]]; then
        log_message SUCCESS "All credentials validated successfully"
        return 0
    else
        log_message ERROR "Credential validation failed"
        return 1
    fi
}

# Export credentials as environment variables
export_credentials() {
    if [[ "$EXPORT_ENV" != "true" ]]; then
        return 0
    fi
    
    log_message INFO "Exporting credentials as environment variables"
    
    if [[ -f "${CREDS_DIR}/splunk_admin_user" ]]; then
        if ! SPLUNK_ADMIN_USER=$(cat "${CREDS_DIR}/splunk_admin_user" 2>/dev/null); then
            log_message WARNING "Could not read admin user for export"
        else
            export SPLUNK_ADMIN_USER
        fi
    fi
    
    if [[ -f "${CREDS_DIR}/splunk_admin_password" ]]; then
        if ! SPLUNK_ADMIN_PASSWORD=$(cat "${CREDS_DIR}/splunk_admin_password" 2>/dev/null); then
            log_message WARNING "Could not read admin password for export"
        else
            export SPLUNK_ADMIN_PASSWORD
        fi
    fi
    
    if [[ -f "${CREDS_DIR}/splunk_secret" ]]; then
        if ! SPLUNK_SECRET=$(cat "${CREDS_DIR}/splunk_secret" 2>/dev/null); then
            log_message WARNING "Could not read splunk secret for export"
        else
            export SPLUNK_SECRET
        fi
    fi
    
    if [[ -f "${CREDS_DIR}/cluster_secret" ]]; then
        if ! CLUSTER_SECRET=$(cat "${CREDS_DIR}/cluster_secret" 2>/dev/null); then
            log_message WARNING "Could not read cluster secret for export"
        else
            export CLUSTER_SECRET
        fi
    fi
    
    log_message SUCCESS "Credentials exported to environment"
}

# Display credential summary
display_summary() {
    echo ""
    echo "====================================="
    echo "Credential Generation Summary"
    echo "====================================="
    echo "Location: $CREDS_DIR"
    echo ""
    echo "Generated Files:"
    
    for file in "${!CREDENTIAL_FILES[@]}"; do
        if [[ -f "${CREDS_DIR}/${file}" ]]; then
            echo -e "  ${GREEN}✓${NC} $file - ${CREDENTIAL_FILES[$file]}"
        else
            echo -e "  ${RED}✗${NC} $file - ${CREDENTIAL_FILES[$file]}"
        fi
    done
    
    if [[ "$GENERATE_CERTS" == "true" ]] && [[ -d "${CREDS_DIR}/certs" ]]; then
        echo ""
        echo "SSL Certificates:"
        echo -e "  ${GREEN}✓${NC} CA certificate and key"
        echo -e "  ${GREEN}✓${NC} Server certificate and key"
        echo "  Validity: $CERT_VALIDITY_DAYS days"
        echo "  Key Size: $KEY_SIZE bits"
    fi
    
    echo ""
    echo "Security Notes:"
    echo "  • Keep these credentials secure"
    echo "  • Do not commit to version control"
    echo "  • Regularly rotate passwords"
    echo "  • Use unique passwords for production"
    echo "====================================="
}

# Main execution
main() {
    log_message INFO "Starting credential generation"
    
    # Register cleanup
    register_cleanup cleanup_credentials
    
    # Parse arguments
    parse_arguments "$@"
    
    # Validate only mode
    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        validate_existing_credentials
        exit $?
    fi
    
    # Get credentials
    get_credentials_interactive
    
    # Validate username if provided
    if [[ -n "$SPLUNK_USER" ]]; then
        validate_username "$SPLUNK_USER"
    else
        SPLUNK_USER="$DEFAULT_USERNAME"
    fi
    
    # Validate or generate password
    if [[ -n "$SPLUNK_PASSWORD" ]]; then
        validate_password "$SPLUNK_PASSWORD" "$SPLUNK_USER"
    elif [[ "$INTERACTIVE" != "true" ]]; then
        error_exit "Password required in non-interactive mode"
    fi
    
    # Create credentials directory
    if ! create_credentials_directory; then
        # Directory exists and user chose not to overwrite
        log_message INFO "Using existing credentials"
        export_credentials
        exit 0
    fi
    
    # Generate and save credentials
    write_credential "splunk_admin_user" "$SPLUNK_USER" "Splunk admin username"
    write_credential "splunk_admin_password" "$SPLUNK_PASSWORD" "Splunk admin password"
    
    # Generate secrets
    write_credential "splunk_secret" "$(generate_secret_key 32)" "Splunk secret key"
    write_credential "cluster_secret" "$(generate_secret_key 32)" "Cluster secret key"
    write_credential "indexer_discovery_secret" "$(generate_secret_key 24)" "Indexer discovery secret"
    write_credential "shc_secret" "$(generate_secret_key 24)" "Search head cluster secret"
    
    # Generate SSL certificates
    generate_ssl_certificates
    
    # Export credentials if requested
    export_credentials
    
    # Display summary
    display_summary
    
    log_message SUCCESS "Credential generation completed successfully"
}

# Execute main function
main "$@"