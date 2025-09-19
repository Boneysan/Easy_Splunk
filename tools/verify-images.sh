#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Verifies resolved image lines and (optionally) checks remote digests.

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_FILE="${RESOLVED_ENV:-$ROOT_DIR/.env.images}"
SKIP_REMOTE_CHECK="${SKIP_REMOTE_CHECK:-false}"
DRY_RUN="${DRY_RUN:-false}"
STRICT="${STRICT:-false}"
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"
METRICS_ENDPOINT="${METRICS_ENDPOINT:-}"

# Lock file
LOCKFILE="/tmp/verify-images.lock"

# Help text
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $0 [OPTIONS]

Verify resolved image references in .env.images file.

Options:
    --dry-run             Show what would be verified without performing remote checks
    --strict              Treat warnings as errors (for CI/CD)
    --help, -h            Show this help message

Environment variables:
    RESOLVED_ENV          Path to resolved images file (default: .env.images)
    SKIP_REMOTE_CHECK     Set to 'true' to skip remote registry checks (default: false)
    DRY_RUN              Set to 'true' for dry run (default: false)
    STRICT               Set to 'true' to treat warnings as errors (default: false)
    SLACK_WEBHOOK        Optional Slack webhook URL for notifications on failures
    METRICS_ENDPOINT     Optional endpoint URL for sending verification metrics

Examples:
    $0                                    # Verify images
    $0 --dry-run                         # Preview verification
    $0 --strict                          # Fail on warnings too
    RESOLVED_ENV=prod.env.images $0      # Verify different file
    SKIP_REMOTE_CHECK=true $0            # Skip remote checks
    STRICT=true $0                       # CI/CD mode - fail on warnings

EOF
    exit 0
fi

# Check for flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN="true"; shift ;;
        --strict) STRICT="true"; shift ;;
        *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
    esac
done

# Acquire lock
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    echo -e "${RED}Another instance is already running${NC}"
    exit 1
fi
trap 'rm -rf "$LOCKFILE"' EXIT

# Validate resolved file exists
if [[ ! -f "$RESOLVED_FILE" ]]; then
    echo -e "${RED}Error: $RESOLVED_FILE not found${NC}"
    echo "Please run tools/resolve-images.sh first to generate the resolved images file."
    exit 1
fi

# Counters
total=0
errors=0
warnings=0
verified=0
remote_checked=0
remote_errors=0

# Main execution
echo -e "${GREEN}=== Verifying images in $RESOLVED_FILE ===${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN MODE] No remote checks will be performed${NC}"
fi
if [[ "$STRICT" == "true" ]]; then
    echo -e "${YELLOW}[STRICT MODE] Warnings will be treated as errors${NC}"
fi
echo "----------------------------------------"

# Phase 1: Validate image reference format
echo -e "${YELLOW}Phase 1: Validating image reference formats...${NC}"

while IFS='=' read -r key value; do
    # Skip empty lines and comments
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    
    ((total++))
    
    # Remove leading/trailing whitespace
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    
    # Check variable naming convention
    if [[ ! "$key" =~ ^[A-Z0-9_]+_IMAGE$ ]]; then
        echo -e "${YELLOW}WARN: Unexpected variable '$key' (expected pattern: *_IMAGE)${NC}"
        ((warnings++))
        continue
    fi
    
    # Validate image reference format
    if [[ "$value" =~ @sha256: ]]; then
        # Digest format validation
        if [[ "$value" =~ ^([^@/:]+(/[^@/:]+)?(/[^@/:]+)?)@sha256:[0-9a-fA-F]{64}$ ]]; then
            echo -e "${GREEN}✓ $key: valid digest format${NC}"
            ((verified++))
        else
            echo -e "${RED}✗ ERROR: Malformed digest image '$value' for $key${NC}"
            echo "  Expected format: [registry/]namespace/repo@sha256:<64-hex-chars>"
            ((errors++))
        fi
    else
        # Tag format validation
        if [[ "$value" =~ ^([^:]+/)?([^:]+):([^:/]+)$ ]]; then
            tag="${BASH_REMATCH[3]}"
            if [[ "$tag" == "latest" ]]; then
                echo -e "${YELLOW}⚠ WARN: $key uses 'latest' tag - consider pinning to specific version${NC}"
                ((warnings++))
            fi
            echo -e "${GREEN}✓ $key: valid tag format${NC}"
            ((verified++))
        else
            echo -e "${RED}✗ ERROR: Missing or invalid tag in '$value' for $key${NC}"
            echo "  Expected format: [registry/]namespace/repo:tag"
            ((errors++))
        fi
    fi
done < "$RESOLVED_FILE"

echo ""
echo -e "${GREEN}Phase 1 complete: $verified/$total images validated, $errors errors, $warnings warnings${NC}"

# Phase 2: Optional remote registry verification
if [[ "${SKIP_REMOTE_CHECK}" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}Skipping remote registry verification (SKIP_REMOTE_CHECK=true)${NC}"
elif [[ "$DRY_RUN" == "true" ]]; then
    echo ""
    echo -e "${YELLOW}[DRY-RUN] Would perform remote registry verification${NC}"
    
    # Show what tools are available
    if command -v skopeo >/dev/null 2>&1; then
        echo "  Tool available: skopeo"
    elif command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        echo "  Tool available: docker buildx"
    elif command -v docker >/dev/null 2>&1; then
        echo "  Tool available: docker manifest"
    else
        echo "  No remote verification tools available"
    fi
else
    echo ""
    echo "----------------------------------------"
    echo -e "${YELLOW}Phase 2: Remote registry verification...${NC}"
    
    # Determine which tool to use for verification
    verifier=""
    if command -v skopeo >/dev/null 2>&1; then
        echo -e "${GREEN}Using skopeo for remote verification...${NC}"
        verifier="skopeo"
    elif command -v docker >/dev/null 2>&1 && docker buildx version >/dev/null 2>&1; then
        echo -e "${GREEN}Using docker buildx for remote verification...${NC}"
        verifier="docker_buildx"
    elif command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN}Using docker manifest for remote verification...${NC}"
        verifier="docker_manifest"
    else
        echo -e "${YELLOW}No tool available for remote verification (install skopeo or docker)${NC}"
        echo -e "${YELLOW}Skipping remote registry checks${NC}"
    fi
    
    if [[ -n "$verifier" ]]; then
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            [[ ! "$key" =~ _IMAGE$ ]] && continue
            
            # Clean whitespace
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"
            
            # Prepare image reference based on verifier
            img="$value"
            
            echo -n "  Checking $key... "
            
            case "$verifier" in
                skopeo)
                    # Handle Docker Hub short forms for skopeo
                    if [[ ! "$img" =~ ^[^/]+\.[^/]+/ ]]; then
                        if [[ ! "$img" =~ / ]]; then
                            # Official image (e.g., "nginx:latest")
                            ref="docker://docker.io/library/$img"
                        else
                            # User image (e.g., "user/repo:tag")
                            ref="docker://docker.io/$img"
                        fi
                    else
                        ref="docker://$img"
                    fi
                    
                    if skopeo inspect "$ref" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                        ((remote_checked++))
                    else
                        echo -e "${RED}✗${NC}"
                        echo -e "  ${RED}ERROR: Cannot inspect $img (check auth/network/existence)${NC}"
                        ((remote_errors++))
                    fi
                    ;;
                    
                docker_buildx)
                    if docker buildx imagetools inspect "$img" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                        ((remote_checked++))
                    else
                        echo -e "${RED}✗${NC}"
                        echo -e "  ${RED}ERROR: Cannot inspect $img (check auth/network/existence)${NC}"
                        ((remote_errors++))
                    fi
                    ;;
                    
                docker_manifest)
                    if docker manifest inspect "$img" >/dev/null 2>&1; then
                        echo -e "${GREEN}✓${NC}"
                        ((remote_checked++))
                    else
                        echo -e "${RED}✗${NC}"
                        echo -e "  ${RED}ERROR: Cannot inspect $img (check auth/network/existence)${NC}"
                        ((remote_errors++))
                    fi
                    ;;
            esac
        done < "$RESOLVED_FILE"
        
        echo ""
        echo -e "${GREEN}Phase 2 complete: $remote_checked images checked, $remote_errors failed${NC}"
        errors=$((errors + remote_errors))
    fi
fi

# Apply strict mode if enabled
if [[ "$STRICT" == "true" ]] && [[ $warnings -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}[STRICT MODE] Treating $warnings warnings as errors${NC}"
    errors=$((errors + warnings))
fi

# Send notification if failures and webhook set
if [[ $errors -gt 0 ]] && [[ -n "$SLACK_WEBHOOK" ]] && [[ "$DRY_RUN" != "true" ]]; then
    message="Image verification failed with $errors errors in $RESOLVED_FILE"
    if [[ "$STRICT" == "true" ]] && [[ $warnings -gt 0 ]]; then
        message="$message (includes $warnings warnings in strict mode)"
    fi
    
    if command -v curl &> /dev/null; then
        curl -X POST "$SLACK_WEBHOOK" \
            -H 'Content-Type: application/json' \
            -d "{\"text\": \"🚨 $message\"}" \
            2>/dev/null || echo -e "${YELLOW}Failed to send Slack notification${NC}"
        echo -e "${GREEN}Sent Slack notification${NC}"
    fi
fi

# Send metrics if endpoint set
if command -v curl &> /dev/null && [[ -n "$METRICS_ENDPOINT" ]] && [[ "$DRY_RUN" != "true" ]]; then
    timestamp=$(date +%s)
    curl -X POST "$METRICS_ENDPOINT" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -d "metric=image_verification&errors=$errors&warnings=$warnings&verified=$verified&remote_checked=$remote_checked&timestamp=$timestamp&tags=file:$(basename $RESOLVED_FILE)" \
        2>/dev/null || echo -e "${YELLOW}Failed to send metrics${NC}"
    echo -e "${GREEN}Sent metrics to monitoring system${NC}"
fi

# Final summary
echo ""
echo "========================================"
if [[ $errors -eq 0 ]]; then
    if [[ $warnings -eq 0 ]]; then
        echo -e "${GREEN}✓ All images verified successfully! ($verified images)${NC}"
    else
        if [[ "$STRICT" != "true" ]]; then
            echo -e "${GREEN}✓ Images verified with $warnings warnings ($verified images)${NC}"
        fi
    fi
    exit 0
else
    if [[ "$STRICT" == "true" ]] && [[ $warnings -gt 0 ]]; then
        echo -e "${RED}✗ Image verification failed with $((errors - warnings)) errors and $warnings warnings (strict mode)${NC}"
    else
        echo -e "${RED}✗ Image verification failed with $errors errors${NC}"
    fi
    exit 2
