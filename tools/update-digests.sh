#!/bin/bash
# Update all digests in versions.env based on current tags
set -euo pipefail
# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
# Configuration
VERSIONS_FILE="${VERSIONS_FILE:-versions.env}"
DRY_RUN="${DRY_RUN:-false}"
# Lock file
LOCKFILE="/tmp/update-digests.lock"
# Help text
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
Usage: $0 [OPTIONS]
Update all image digests in versions.env based on current tags.
Options:
    --dry-run Show what would be updated without making changes
    --help, -h Show this help message
Environment variables:
    VERSIONS_FILE Path to versions file (default: versions.env)
    DRY_RUN Set to 'true' for dry run (default: false)
Example:
    $0 # Update all digests
    $0 --dry-run # Preview changes
    VERSIONS_FILE=prod.env $0 # Update different file
EOF
    exit 0
fi
# Check for dry-run flag
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="true"
fi
# Acquire lock
if ! mkdir "$LOCKFILE" 2>/dev/null; then
    echo -e "${RED}Another instance is already running${NC}"
    exit 1
fi
trap 'rm -rf "$LOCKFILE"' EXIT
# Validate versions file exists
if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo -e "${RED}Error: $VERSIONS_FILE not found${NC}"
    exit 1
fi
# Function to update a single digest
update_digest() {
    local repo=$1
    local tag=$2
    local prefix=$3
   
    echo -e "${YELLOW}Updating ${prefix}_IMAGE_DIGEST...${NC}"
   
    # Pull the image
    if ! docker pull --platform linux/amd64 --quiet "${repo}:${tag}" > /dev/null 2>&1; then
        echo -e "${RED} Failed to pull ${repo}:${tag}${NC}"
        return 1
    fi
   
    # Get the digest
    local full_digest=$(docker inspect --format '{{index .RepoDigests 0}}' "${repo}:${tag}" 2>/dev/null | cut -d '@' -f 2)
   
    if [[ -z "$full_digest" ]]; then
        echo -e "${RED} Failed to get digest for ${repo}:${tag}${NC}"
        return 1
    fi
   
    # Check if digest changed
    local current_digest=$(grep "^# ${prefix}_IMAGE_DIGEST=" "$VERSIONS_FILE" 2>/dev/null | cut -d '=' -f 2)
   
    if [[ "$current_digest" == "$full_digest" ]]; then
        echo -e "${GREEN} ✓ ${prefix} digest unchanged${NC}"
    else
        echo -e "${GREEN} ✓ ${prefix} new digest: ${full_digest:0:12}...${NC}"
       
        # Update the versions file (unless dry-run)
        if [[ "$DRY_RUN" == "false" ]]; then
            sed -i "s|^# ${prefix}_IMAGE_DIGEST=.*|# ${prefix}_IMAGE_DIGEST=${full_digest}|" "$VERSIONS_FILE"
        else
            echo -e " ${YELLOW}[DRY-RUN] Would update digest${NC}"
        fi
    fi
}
# Main execution
echo -e "${GREEN}=== Updating digests in $VERSIONS_FILE ===${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN MODE] No changes will be made${NC}"
fi
# Create backup if not dry-run
if [[ "$DRY_RUN" == "false" ]]; then
    cp "$VERSIONS_FILE" "${VERSIONS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    echo -e "${GREEN}Created backup of $VERSIONS_FILE${NC}"
fi
# Extract all prefixes from the DIGEST lines
prefixes=$(grep '_IMAGE_DIGEST=' "$VERSIONS_FILE" | sed 's/^# //' | cut -d '_' -f 1 | sort -u)
if [[ -z "$prefixes" ]]; then
    echo -e "${RED}No image digests found in $VERSIONS_FILE${NC}"
    exit 1
fi
# Track statistics
total=0
updated=0
failed=0
# Process each prefix
for prefix in $prefixes; do
    ((total++))
   
    # Extract repo (handling commented or uncommented lines)
    repo_line=$(grep "^${prefix}_IMAGE_REPO=" "$VERSIONS_FILE" || grep "^# ${prefix}_IMAGE_REPO=" "$VERSIONS_FILE" || true)
    if [[ -z "$repo_line" ]]; then
        echo -e "${RED}Warning: No repo found for ${prefix}${NC}"
        ((failed++))
        continue
    fi
    repo=$(echo "$repo_line" | sed 's/^# //' | cut -d '=' -f 2)
   
    # Extract tag (handling commented or uncommented lines)
    tag_line=$(grep "^${prefix}_IMAGE_TAG=" "$VERSIONS_FILE" || grep "^# ${prefix}_IMAGE_TAG=" "$VERSIONS_FILE" || true)
    if [[ -z "$tag_line" ]]; then
        echo -e "${YELLOW}Skipping ${prefix}: No tag defined (using digest only?)${NC}"
        continue
    fi
    tag=$(echo "$tag_line" | sed 's/^# //' | cut -d '=' -f 2)
   
    if update_digest "$repo" "$tag" "$prefix"; then
        ((updated++))
    else
        ((failed++))
    fi
done
# Update metadata if present and not in dry-run
if grep -q "^# Last Updated:" "$VERSIONS_FILE" 2>/dev/null; then
    if [[ "$DRY_RUN" == "false" ]]; then
        current_date=$(date +%Y-%m-%d)
        sed -i "s/^# Last Updated: .*/# Last Updated: ${current_date}/" "$VERSIONS_FILE"
        echo -e "${GREEN}Updated metadata date to ${current_date}${NC}"
    else
        echo -e "${YELLOW}[DRY-RUN] Would update metadata date${NC}"
    fi
fi
# Summary
echo -e "${GREEN}=== Summary ===${NC}"
echo -e "Total images: ${total}"
echo -e "Successfully processed: ${updated}"
if [[ $failed -gt 0 ]]; then
    echo -e "${RED}Failed: ${failed}${NC}"
fi
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN] No changes were made. Remove --dry-run to apply changes.${NC}"
else
    echo -e "${GREEN}✓ Digests and metadata updated in $VERSIONS_FILE${NC}"
fi
# Exit with error if any updates failed
[[ $failed -eq 0 ]] || exit 1