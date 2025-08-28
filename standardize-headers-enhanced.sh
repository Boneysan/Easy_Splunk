#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Enhanced universal header standardization script
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
    
    # Check if it already has the complete universal header
    if head -6 "$script_file" | grep -q "set -Eeuo pipefail" && 
       head -6 "$script_file" | grep -q "IFS=.*\$.*n.*t" &&
       head -6 "$script_file" | grep -q "shopt -s lastpipe"; then
        echo "  - Already has complete universal header, skipping"
        return 0
    fi
    
    # Create backup
    cp "$script_file" "${script_file}.fix_bak"
    
    # Process the file
    {
        # Add universal header
        echo -n "$UNIVERSAL_HEADER"
        
        # Add the rest of the file, skipping existing shebang and redundant settings
        local skip_next_blank=false
        tail -n +2 "$script_file" | while IFS= read -r line; do
            # Skip existing headers and common patterns that are redundant
            if [[ "$line" =~ ^#!/.*bash ]] ||
               [[ "$line" =~ ^set[[:space:]]+-[euxoEpipefail] ]] ||
               [[ "$line" =~ ^IFS= ]] ||
               [[ "$line" =~ ^shopt[[:space:]]+-s[[:space:]]+lastpipe ]] ||
               [[ "$line" =~ ^#[[:space:]]*shellcheck[[:space:]]+shell=bash ]] ||
               [[ "$line" =~ ^#[[:space:]]*Strict[[:space:]]+IFS ]]; then
                skip_next_blank=true
                continue
            fi
            
            # Skip blank lines immediately following removed headers
            if [[ -z "$line" && "$skip_next_blank" == true ]]; then
                skip_next_blank=false
                continue
            fi
            
            skip_next_blank=false
            echo "$line"
        done
    } > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$script_file"
    
    # Preserve executable permissions
    chmod +x "$script_file"
    
    echo "  - Updated successfully"
}

# Count scripts to process
echo "=== Enhanced Bash Script Header Standardization ==="
script_count=$(find "$SCRIPT_DIR" -name "*.sh" -type f -executable | wc -l)
echo "Found $script_count executable bash scripts to process"
echo

# Process all executable bash scripts
processed=0
while IFS= read -r -d '' script_file; do
    standardize_script_header "$script_file"
    ((processed++))
done < <(find "$SCRIPT_DIR" -name "*.sh" -type f -executable -print0)

echo
echo "=== Enhanced Header Standardization Complete ==="
echo "Processed $processed executable bash scripts."
echo "All scripts now have the universal header:"
echo "  - #!/usr/bin/env bash"
echo "  - set -Eeuo pipefail"
echo "  - shopt -s lastpipe 2>/dev/null || true" 
echo "  - IFS=\$'\\n\\t'"
echo
echo "Backup files created with .fix_bak extension."
