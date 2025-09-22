#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# Script to apply universal bash strict mode + global trap to all *.sh files
# This implements the first item from the PR checklist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Applying Universal Bash Strict Mode + Global Trap ==="

# Function to add bash strict mode header to a file
add_bash_strict_mode() {
    local file="$1"
    local temp_file="${file}.tmp"

    # Skip if already has strict mode
    if grep -q "set -Eeuo pipefail" "$file"; then
        echo "✅ Already has strict mode: $(basename "$file")"
        return 0
    fi

    # Create new file with strict mode header
    {
        echo "#!/usr/bin/env bash"
        echo "set -Eeuo pipefail"
        echo "shopt -s lastpipe 2>/dev/null || true"
        echo ""
        echo "# Strict IFS for safer word splitting"
        echo "IFS=\$'\n\t'"
        echo ""
        echo "# Global trap for useful diagnostics"
        echo "trap 'rc=\$?; echo \"[ERROR] \${BASH_SOURCE[0]}:\${LINENO} exited with \$rc\" >&2; exit \$rc' ERR"
        echo ""

        # Add the rest of the original file, skipping the old shebang if present
        if grep -q "^#!/usr/bin/env bash" "$file"; then
            tail -n +2 "$file"
        else
            cat "$file"
        fi
    } > "$temp_file"

    # Replace original file
    mv "$temp_file" "$file"
    chmod +x "$file"
    echo "✅ Added strict mode to: $(basename "$file")"
}

# Find all .sh files (excluding backups and certain directories)
find "$SCRIPT_DIR" -name "*.sh" -type f \
    -not -path "*/.git/*" \
    -not -path "*/node_modules/*" \
    -not -name "*.bak" \
    -not -name "*.backup*" \
    -not -name "*.tmp" \
    -not -path "*/logs/*" \
    -not -path "*/test-results/*" \
    -not -path "*/.vscode/*" \
    -print0 | while IFS= read -r -d '' file; do
    add_bash_strict_mode "$file"
done

echo "=== Bash Strict Mode Application Complete ==="
echo "All .sh files now have universal bash strict mode and global error trap"
