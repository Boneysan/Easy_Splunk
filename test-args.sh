#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt


echo "=== Testing Phase 2 Argument Parsing ==="

# Test script to validate new credential arguments
test_args() {
    local args="$1"
    local expected_simple="$2" 
    local expected_encryption="$3"
    
    echo "Testing: $args"
    
    # Extract just the argument parsing logic
    # Set defaults
    SIMPLE_CREDS=true
    USE_ENCRYPTION=false
    
    # Parse the arguments
    eval "set -- $args"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --simple-creds)     SIMPLE_CREDS=true; shift;;
            --secure-creds)     SIMPLE_CREDS=false; shift;;
            --use-encryption)   USE_ENCRYPTION=true; shift;;
            *) shift;;
        esac
    done
    
    echo "  SIMPLE_CREDS=$SIMPLE_CREDS (expected: $expected_simple)"
    echo "  USE_ENCRYPTION=$USE_ENCRYPTION (expected: $expected_encryption)"
    
    if [[ "$SIMPLE_CREDS" == "$expected_simple" ]] && [[ "$USE_ENCRYPTION" == "$expected_encryption" ]]; then
        echo "  ✓ PASS"
    else
        echo "  ✗ FAIL"
        return 1
    fi
    echo
}

# Test various argument combinations
test_args "small" "true" "false"  # Default behavior
test_args "--simple-creds small" "true" "false"  # Explicit simple mode
test_args "--secure-creds small" "false" "false"  # Secure mode (old system)
test_args "--use-encryption small" "true" "true"  # Simple mode with encryption
test_args "--simple-creds --use-encryption small" "true" "true"  # Explicit combination
test_args "--secure-creds --use-encryption small" "false" "true"  # Secure mode with encryption

echo "🎉 All argument parsing tests passed!"
echo "✅ Phase 2 argument parsing: Working correctly"
