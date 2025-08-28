#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# verify-image-references.sh  
# Standalone script to verify image reference consistency across Easy_Splunk
#
# Purpose: Prevents configuration drift by ensuring all image references
#          use centralized variables from versions.env
#
# Usage:
#   ./verify-image-references.sh [compose-file]
#   ./verify-image-references.sh --audit [compose-file]  
#   ./verify-image-references.sh --fix [compose-file]
#   ./verify-image-references.sh --show-sanctioned
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load dependencies
source lib/core.sh
source versions.env
source lib/image-validator.sh

# Default values
ACTION="validate"
COMPOSE_FILE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --audit)
            ACTION="audit"
            shift
            ;;
        --fix)
            ACTION="fix"
            shift
            ;;
        --show-sanctioned)
            ACTION="show-sanctioned"
            shift
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [OPTIONS] [COMPOSE_FILE]

Verify image reference consistency across Easy_Splunk deployment.

OPTIONS:
  --audit           Show detailed audit of image references
  --fix             Attempt automatic fixes for common issues
  --show-sanctioned Display list of sanctioned image variables
  --help, -h        Show this help message

COMPOSE_FILE:
  Path to docker-compose.yml file to validate.
  If not specified, will look for docker-compose.yml in current directory.

EXAMPLES:
  $0                                    # Validate docker-compose.yml
  $0 custom-compose.yml                 # Validate specific file
  $0 --audit docker-compose.yml        # Detailed audit
  $0 --fix docker-compose.yml          # Attempt automatic fixes
  $0 --show-sanctioned                 # Show approved variables

EXIT CODES:
  0 - Success (validation passed)
  1 - Validation failed or error occurred
  2 - Invalid arguments
EOF
            exit 0
            ;;
        -*)
            echo "Error: Unknown option $1" >&2
            echo "Use --help for usage information." >&2
            exit 2
            ;;
        *)
            if [[ -z "$COMPOSE_FILE" ]]; then
                COMPOSE_FILE="$1"
            else
                echo "Error: Multiple compose files specified" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

# Set default compose file if not specified
if [[ -z "$COMPOSE_FILE" && "$ACTION" != "show-sanctioned" ]]; then
    COMPOSE_FILE="docker-compose.yml"
fi

# Execute requested action
case "$ACTION" in
    "validate")
        echo "=== IMAGE REFERENCE VALIDATION ==="
        echo "Compose file: $COMPOSE_FILE"
        echo ""
        
        if [[ ! -f "$COMPOSE_FILE" ]]; then
            log_error "Compose file not found: $COMPOSE_FILE"
            exit 1
        fi
        
        # Check versions.env completeness first
        if ! check_versions_env_completeness; then
            log_error "versions.env is incomplete"
            exit 1
        fi
        
        # Validate the compose file
        if validate_image_references "$COMPOSE_FILE"; then
            echo ""
            log_success "🎉 Image reference validation PASSED"
            echo "All image references use sanctioned variables from versions.env"
            exit 0
        else
            echo ""
            log_error "💥 Image reference validation FAILED"
            echo "Run with --audit for detailed analysis"
            echo "Run with --fix to attempt automatic repairs"
            exit 1
        fi
        ;;
        
    "audit")
        echo "=== COMPREHENSIVE IMAGE REFERENCE AUDIT ==="
        echo "Compose file: $COMPOSE_FILE"
        echo ""
        
        if [[ ! -f "$COMPOSE_FILE" ]]; then
            log_error "Compose file not found: $COMPOSE_FILE"
            exit 1
        fi
        
        audit_image_references "$COMPOSE_FILE"
        ;;
        
    "fix")
        echo "=== AUTOMATIC IMAGE REFERENCE FIX ==="
        echo "Compose file: $COMPOSE_FILE"
        echo ""
        
        if [[ ! -f "$COMPOSE_FILE" ]]; then
            log_error "Compose file not found: $COMPOSE_FILE"
            exit 1
        fi
        
        fix_image_references "$COMPOSE_FILE"
        
        echo ""
        echo "Re-running validation..."
        if validate_image_references "$COMPOSE_FILE"; then
            log_success "🎉 Fixes applied successfully - validation now passes"
            exit 0
        else
            log_warning "⚠️  Automatic fixes insufficient - manual intervention required"
            exit 1
        fi
        ;;
        
    "show-sanctioned")
        show_sanctioned_variables
        echo ""
        echo "To add new sanctioned variables:"
        echo "1. Update versions.env with the new image variable"
        echo "2. Add the variable name to SANCTIONED_IMAGE_VARS in lib/image-validator.sh"
        echo "3. Update compose templates to use the new variable"
        exit 0
        ;;
        
    *)
        log_error "Unknown action: $ACTION"
        exit 2
        ;;
esac
