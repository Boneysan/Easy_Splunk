#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Universal header standardization script
# Adds consistent bash header to all executable bash scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The universal header to add
UNIVERSAL_HEADER='#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

'

standardize_script_header() {
    local script_file="$1"
    local temp_file="${script_file}.tmp"
    
    echo "Processing: $script_file"
    
    # Read the current file
    if [[ ! -f "$script_file" ]]; then
        echo "  - File not found, skipping"
        return 1
    fi
    
    # Check if it's already properly formatted
    if head -6 "$script_file" | grep -q "set -Eeuo pipefail" && 
       head -6 "$script_file" | grep -q "IFS="; then
        echo "  - Already has universal header, skipping"
        return 0
    fi
    
    # Create backup
    cp "$script_file" "${script_file}.bak"
    
    # Process the file
    {
        # Add universal header
        echo -n "$UNIVERSAL_HEADER"
        
        # Add the rest of the file, skipping existing shebang and basic set commands
        tail -n +2 "$script_file" | while IFS= read -r line; do
            # Skip common variations of set commands and IFS that might exist
            if [[ "$line" =~ ^set[[:space:]]+-[euxoE] ]] || 
               [[ "$line" =~ ^IFS= ]] ||
               [[ "$line" =~ ^shopt[[:space:]]+-s[[:space:]]+lastpipe ]]; then
                continue
            fi
            echo "$line"
        done
    } > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$script_file"
    
    # Preserve executable permissions
    chmod +x "$script_file"
    
    echo "  - Updated successfully"
}

# Process all executable bash scripts
echo "=== Standardizing Bash Script Headers ==="
echo

# Get all executable .sh files
while IFS= read -r -d '' script_file; do
    standardize_script_header "$script_file"
done < <(find "$SCRIPT_DIR" -name "*.sh" -type f -executable -print0)

echo
echo "=== Header Standardization Complete ==="
echo "All executable bash scripts now have the universal header."
echo "Backup files created with .bak extension."
