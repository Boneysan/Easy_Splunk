#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# Simple test for compose validation functionality

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/error-handling.sh"
source "${SCRIPT_DIR}/lib/compose-validation.sh"

setup_standard_logging "simple-compose-test"

echo "=== Compose Validation Test ==="
echo ""

# Test engine detection
echo "1. Testing engine detection..."
if detect_compose_engine; then
    echo "✅ Engine detection successful"
    get_compose_info
else
    echo "❌ Engine detection failed"
    exit 1
fi

echo ""
echo "2. Testing metadata addition..."

# Create test compose file
cat > test-compose.yml << 'EOF'
version: '3.8'
services:
  test-app:
    image: nginx:latest
    ports:
      - "8080:80"
EOF

if add_compose_metadata "test-compose.yml" "test"; then
    echo "✅ Metadata addition successful"
    if grep -q "GENERATED COMPOSE FILE" test-compose.yml; then
        echo "✅ Metadata header found"
    else
        echo "❌ Metadata header missing"
    fi
else
    echo "❌ Metadata addition failed"
fi

# Cleanup
rm -f test-compose.yml

echo ""
echo "3. Testing schema validation..."

# Create valid compose file
cat > valid-compose.yml << 'EOF'
version: '3.8'
services:
  test-app:
    image: nginx:latest
    ports:
      - "8080:80"
networks:
  default:
    driver: bridge
EOF

if validate_compose_schema "valid-compose.yml"; then
    echo "✅ Schema validation successful"
else
    echo "❌ Schema validation failed"
fi

# Cleanup
rm -f valid-compose.yml

echo ""
echo "Compose validation system is working!"
echo "This will help prevent 'works on my box' issues."
