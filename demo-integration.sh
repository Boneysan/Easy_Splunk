#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR

# Demo integration script showing how lint-compose.sh integrates with deploy.sh
# This demonstrates the post-generation linting concept

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Demo: Post-Generation Compose Linting Integration ==="
echo

# Simulate compose file generation (normally done by lib/compose-generator.sh)
echo "1. [SIMULATED] Generating docker-compose files..."
echo "   - Main compose: docker-compose.yml"
echo "   - Monitoring: docker-compose.monitoring.yml (if enabled)"
echo

# Run post-generation linter (this is the new integration point)
echo "2. Running post-generation compose linter..."
echo

compose_files=("docker-compose.yml")

linter_script="${SCRIPT_DIR}/lint-compose.sh"
if [[ ! -x "$linter_script" ]]; then
    echo "ERROR: Compose linter not found or not executable: $linter_script"
    exit 1
fi

all_passed=1
for compose_file in "${compose_files[@]}"; do
    if [[ -f "$compose_file" ]]; then
        echo "   Linting: $compose_file"
        if "$linter_script" "$compose_file"; then
            echo "   ✅ PASSED: $compose_file"
        else
            echo "   ❌ FAILED: $compose_file"
            all_passed=0
        fi
        echo
    else
        echo "   ⚠️  SKIP: $compose_file (not found)"
    fi
done

echo "3. Linting Results:"
if (( all_passed )); then
    echo "   ✅ All compose files passed linting - proceeding with deployment"
    echo
    echo "4. [SIMULATED] Would now run:"
    echo "   docker/podman compose up -d"
    echo
    echo "✅ Integration demo completed successfully!"
    exit 0
else
    echo "   ❌ One or more compose files failed linting"
    echo "   🛑 Deployment blocked due to policy violations"
    echo
    echo "💡 Fix the issues above and try again."
    exit 1
fi
