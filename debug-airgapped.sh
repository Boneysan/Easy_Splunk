#!/usr/bin/env bash
set -Eeuo pipefail

echo "Step 1: Starting debug script"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Step 2: SCRIPT_DIR=$SCRIPT_DIR"

echo "Step 3: Sourcing core.sh..."
source "${SCRIPT_DIR}/lib/core.sh"
echo "Step 4: core.sh loaded"

echo "Step 5: Sourcing error-handling.sh..."
source "${SCRIPT_DIR}/lib/error-handling.sh"
echo "Step 6: error-handling.sh loaded"

echo "Step 7: Sourcing security.sh..."
source "${SCRIPT_DIR}/lib/security.sh"
echo "Step 8: security.sh loaded"

echo "Step 9: Sourcing versions.env..."
source <(sed 's/\r$//' "${SCRIPT_DIR}/versions.env")
echo "Step 10: versions.env loaded"

echo "Step 11: Sourcing versions.sh..."
source "${SCRIPT_DIR}/lib/versions.sh"
echo "Step 12: versions.sh loaded"

echo "Step 13: Sourcing runtime.sh..."
source "${SCRIPT_DIR}/lib/runtime.sh"
echo "Step 14: runtime.sh loaded"

echo "Step 15: Sourcing air-gapped.sh..."
source "${SCRIPT_DIR}/lib/air-gapped.sh"
echo "Step 16: air-gapped.sh loaded"

echo "Step 17: Setting up logging..."
setup_standard_logging "debug-airgapped"
echo "Step 18: Logging setup complete"

echo "Step 19: All dependencies loaded successfully!"
echo "Step 20: Testing argument parsing..."

if [[ "${1:-}" == "--help" ]]; then
    echo "Help requested - would show usage here"
    exit 0
fi

echo "Step 21: Script completed successfully"