#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# Script to update all files to source the new consolidated lib/runtime.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Updating Runtime Library References ==="

# Function to update runtime library references in a file
update_runtime_reference() {
    local file="$1"

    # Skip if already updated
    if grep -q "source.*lib/runtime.sh" "$file"; then
        echo "✅ Already updated: $(basename "$file")"
        return 0
    fi

    # Replace old runtime-detection.sh references with new runtime.sh
    sed -i 's|lib/runtime-detection\.sh|lib/runtime.sh|g' "$file"
    sed -i 's|runtime-detection\.sh|runtime.sh|g' "$file"

    echo "✅ Updated: $(basename "$file")"
}

# Find all .sh files that reference runtime-detection.sh
grep -l "runtime-detection\.sh" "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/**/*.sh 2>/dev/null | while read -r file; do
    update_runtime_reference "$file"
done

echo "=== Runtime Library Update Complete ==="
echo "All files now source the consolidated lib/runtime.sh"
