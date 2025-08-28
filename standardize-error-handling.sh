#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# standardize-error-handling.sh - Script to standardize error handling across all scripts


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load the error handling library to ensure it works
source lib/error-handling.sh

show_help() {
    cat << 'EOF'
standardize-error-handling.sh - Standardize error handling across scripts

This script helps update all shell scripts to use the standardized error handling
from lib/error-handling.sh.

USAGE:
    ./standardize-error-handling.sh [OPTIONS] [SCRIPT_PATH]

OPTIONS:
    --check          Check which scripts need updating (default)
    --update         Update scripts to use standardized error handling
    --backup         Create backups before updating
    --help           Show this help

ARGUMENTS:
    SCRIPT_PATH      Path to specific script to update (optional)

EXAMPLES:
    ./standardize-error-handling.sh --check              # Check all scripts
    ./standardize-error-handling.sh --check deploy.sh    # Check specific script
    ./standardize-error-handling.sh --update             # Update all scripts
    ./standardize-error-handling.sh --update deploy.sh   # Update specific script

The script will:
1. Check if scripts use standardized error handling
2. Update scripts to load lib/error-handling.sh first
3. Remove fallback functions and use standardized ones
4. Add setup_standard_logging calls
EOF
}

# Check if a script uses standardized error handling
check_script() {
    local script_path="$1"

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    local status="UNKNOWN"
    local issues=()

    # Check for standardized error handling
    if grep -q "setup_standard_logging" "$script_path"; then
        status="STANDARDIZED"
    elif grep -q "source.*error-handling.sh" "$script_path"; then
        status="PARTIALLY_STANDARDIZED"
        issues+=("Uses error-handling.sh but missing setup_standard_logging")
    elif grep -q "log_message.*fallback" "$script_path"; then
        status="HAS_FALLBACKS"
        issues+=("Has fallback functions that should be removed")
    elif grep -q "set -e" "$script_path" && ! grep -q "source.*error-handling.sh" "$script_path"; then
        status="BASIC_ERROR_HANDLING"
        issues+=("Uses basic set -e but no standardized error handling")
    else
        status="UNKNOWN_PATTERN"
        issues+=("Unrecognized error handling pattern")
    fi

    echo "$status|$script_path|${issues[*]}"
}

# Update a script to use standardized error handling
update_script() {
    local script_path="$1"
    local create_backup="${2:-false}"

    if [[ ! -f "$script_path" ]]; then
        log_error "Script not found: $script_path"
        return 1
    fi

    log_info "Updating $script_path..."

    # Create backup if requested
    if [[ "$create_backup" == "true" ]]; then
        cp "$script_path" "${script_path}.backup-$(date +%Y%m%d_%H%M%S)"
        log_info "Created backup: ${script_path}.backup-$(date +%Y%m%d_%H%M%S)"
    fi

    # Read the current script
    local script_content
    script_content=$(cat "$script_path")

    # Check if it already has standardized error handling
    if grep -q "setup_standard_logging" "$script_path"; then
        log_warning "$script_path already uses standardized error handling"
        return 0
    fi

    # Extract the shebang and initial comments
    local shebang=""
    local header=""
    local rest=""

    if [[ "$script_content" =~ ^(#!/.*)$ ]]; then
        shebang="${BASH_REMATCH[1]}"
        script_content="${script_content#"$shebang"}"
    fi

    # Find where the main script starts (after comments)
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done <<< "$script_content"

    local script_start=0
    for i in "${!lines[@]}"; do
        if [[ "${lines[$i]}" =~ ^[^#] ]] && [[ ! "${lines[$i]}" =~ ^[[:space:]]*$ ]]; then
            script_start=$i
            break
        fi
    done

    # Create the new script content
    local new_content="$shebang
"

    # Add header comments up to script start
    for ((i = 0; i < script_start; i++)); do
        new_content+="${lines[$i]}
"
    done

    # Add standardized error handling setup
    new_content+="
# ============================= Script Configuration ===========================
SCRIPT_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"

# Load standardized error handling first
source \"\${SCRIPT_DIR}/lib/error-handling.sh\" || {
    echo \"ERROR: Failed to load error handling library\" >&2
    exit 1
}

# Setup standardized logging
setup_standard_logging \"$(basename "$script_path" .sh)\"

# Set error handling
"

    # Add the rest of the script, but remove fallback functions
    local in_fallback_section=false
    for ((i = script_start; i < ${#lines[@]}; i++)); do
        local line="${lines[$i]}"

        # Detect fallback function sections
        if [[ "$line" =~ BEGIN.*Fallback.*error.handle ]]; then
            in_fallback_section=true
            continue
        fi

        if [[ "$line" =~ END.*Fallback.*error.handle ]]; then
            in_fallback_section=false
            continue
        fi

        # Skip fallback functions
        if [[ "$in_fallback_section" == "true" ]]; then
            continue
        fi

        # Skip existing error_exit definitions
        if [[ "$line" =~ ^error_exit\(\) ]]; then
            # Skip until the end of the function
            while [[ "$line" != "}" ]] && ((i < ${#lines[@]})); do
                ((i++))
                line="${lines[$i]}"
            done
            continue
        fi

        # Skip set -euo pipefail if we already added it
        if [[ "$line" == "set -euo pipefail" ]]; then
            continue
        fi

        new_content+="$line
"
    done

    # Write the new content
    echo "$new_content" > "$script_path"

    log_success "Updated $script_path with standardized error handling"
}

# Find all shell scripts in the project
find_scripts() {
    # Find all .sh files except in certain directories
    find . -name "*.sh" -type f \
        -not -path "./.*" \
        -not -path "./node_modules/*" \
        -not -path "./.git/*" \
        | sort
}

# Main function
main() {
    local action="check"
    local script_path=""
    local create_backup=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --check)
                action="check"
                shift
                ;;
            --update)
                action="update"
                shift
                ;;
            --backup)
                create_backup=true
                shift
                ;;
            --help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                script_path="$1"
                shift
                ;;
        esac
    done

    if [[ "$action" == "check" ]]; then
        if [[ -n "$script_path" ]]; then
            # Check specific script
            local result
            result=$(check_script "$script_path")
            IFS='|' read -r status path issues <<< "$result"

            echo "=== Script Status ==="
            echo "Script: $path"
            echo "Status: $status"
            if [[ -n "$issues" ]]; then
                echo "Issues: $issues"
            fi
        else
            # Check all scripts
            echo "=== Checking All Scripts ==="
            local scripts
            mapfile -t scripts < <(find_scripts)

            for script in "${scripts[@]}"; do
                local result
                result=$(check_script "$script")
                IFS='|' read -r status path issues <<< "$result"

                case "$status" in
                    "STANDARDIZED")
                        log_success "✅ $script - Fully standardized"
                        ;;
                    "PARTIALLY_STANDARDIZED")
                        log_warning "⚠️  $script - Partially standardized ($issues)"
                        ;;
                    "HAS_FALLBACKS")
                        log_warning "⚠️  $script - Has fallback functions ($issues)"
                        ;;
                    "BASIC_ERROR_HANDLING")
                        log_info "ℹ️  $script - Basic error handling ($issues)"
                        ;;
                    *)
                        log_info "?️  $script - $status ($issues)"
                        ;;
                esac
            done
        fi
    elif [[ "$action" == "update" ]]; then
        if [[ -n "$script_path" ]]; then
            # Update specific script
            update_script "$script_path" "$create_backup"
        else
            # Update all scripts that need it
            log_info "Finding scripts that need updating..."
            local scripts
            mapfile -t scripts < <(find_scripts)

            for script in "${scripts[@]}"; do
                local result
                result=$(check_script "$script")
                IFS='|' read -r status path issues <<< "$result"

                if [[ "$status" != "STANDARDIZED" ]]; then
                    log_info "Updating $script..."
                    update_script "$script" "$create_backup"
                else
                    log_info "Skipping $script (already standardized)"
                fi
            done
        fi
    fi
}

# Run main function with all arguments
main "$@"
