#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# tests/run_tests.sh
# Main test runner with code coverage tracking
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Coverage tracking variables
declare -A FUNCTION_CALLS
declare -A FUNCTION_COVERAGE

# Function to track function calls
trace_function() {
    local func_name="$1"
    FUNCTION_CALLS["$func_name"]=$((FUNCTION_CALLS["$func_name"] + 1))
}

# Enable function tracing
enable_coverage_tracking() {
    # Save original PS4 value
    OLD_PS4=$PS4
    
    # Set PS4 to trace function calls
    PS4='$(trace_function "${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}") +${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-main}: '
    
    # Enable tracing
    set -x
}

# Disable function tracing
disable_coverage_tracking() {
    # Restore original PS4
    PS4=$OLD_PS4
    
    # Disable tracing
    set +x
}

# Initialize coverage tracking
initialize_coverage() {
    local files=(
        "${SCRIPT_DIR}/../lib/core.sh"
        "${SCRIPT_DIR}/../lib/validation.sh"
        "${SCRIPT_DIR}/../lib/security.sh"
        "${SCRIPT_DIR}/../lib/error-handling.sh"
        "${SCRIPT_DIR}/../scripts/validation/input_validator.sh"
    )
    
    # Get all function definitions
    for file in "${files[@]}"; do
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*(function[[:space:]]+)?([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*\(\) ]]; then
                local func_name="${BASH_REMATCH[2]}"
                FUNCTION_CALLS["$func_name"]=0
                FUNCTION_COVERAGE["$func_name"]=0
            fi
        done < "$file"
    done
}

# Calculate and display coverage report
generate_coverage_report() {
    local total_functions=0
    local covered_functions=0
    
    echo
    echo "=========================================="
    echo "Code Coverage Report"
    echo "=========================================="
    echo
    
    # Sort function names for consistent output
    local -a sorted_functions
    for func in "${!FUNCTION_CALLS[@]}"; do
        sorted_functions+=("$func")
    done
    IFS=$'\n' sorted_functions=($(sort <<<"${sorted_functions[*]}"))
    unset IFS
    
    # Calculate coverage for each function
    for func in "${sorted_functions[@]}"; do
        local calls=${FUNCTION_CALLS["$func"]}
        ((total_functions++))
        if ((calls > 0)); then
            ((covered_functions++))
            FUNCTION_COVERAGE["$func"]=100
            echo -e "${GREEN}✓${NC} $func: $calls calls (100% coverage)"
        else
            FUNCTION_COVERAGE["$func"]=0
            echo -e "${RED}✗${NC} $func: Not called (0% coverage)"
        fi
    done
    
    # Calculate total coverage
    local coverage=$((covered_functions * 100 / total_functions))
    echo
    echo "=========================================="
    echo "Total Coverage: $coverage% ($covered_functions/$total_functions functions)"
    echo "=========================================="
    
    # Check if we met the 80% threshold
    if ((coverage >= 80)); then
        echo -e "${GREEN}✓ Coverage threshold met (≥80%)${NC}"
        return 0
    else
        echo -e "${RED}✗ Coverage threshold not met (<80%)${NC}"
        return 1
    fi
}

# Run all unit tests with coverage tracking
run_all_tests() {
    local test_files=(
        "${SCRIPT_DIR}/unit/test_validation.sh"
        "${SCRIPT_DIR}/unit/test_configuration.sh"
        "${SCRIPT_DIR}/unit/test_credentials.sh"
        "${SCRIPT_DIR}/unit/test_networking.sh"
    )
    
    local failed_tests=()
    local pass_count=0
    local fail_count=0
    
    # Initialize coverage tracking
    initialize_coverage
    enable_coverage_tracking
    
    # Run each test file
    for test_file in "${test_files[@]}"; do
        echo "Running tests from $(basename "$test_file")..."
        if bash "$test_file"; then
            ((pass_count++))
            echo -e "${GREEN}✓ $(basename "$test_file") passed${NC}"
        else
            ((fail_count++))
            failed_tests+=("$(basename "$test_file")")
            echo -e "${RED}✗ $(basename "$test_file") failed${NC}"
        fi
        echo
    done
    
    # Disable coverage tracking and generate report
    disable_coverage_tracking
    generate_coverage_report
    
    # Print test summary
    echo
    echo "=========================================="
    echo "Test Summary"
    echo "=========================================="
    echo "Total test files: $((pass_count + fail_count))"
    echo -e "${GREEN}Passed: $pass_count${NC}"
    if ((fail_count > 0)); then
        echo -e "${RED}Failed: $fail_count${NC}"
        echo "Failed tests:"
        for test in "${failed_tests[@]}"; do
            echo -e "${RED}  - $test${NC}"
        done
        return 1
    fi
    return 0
}

# Run the tests if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_all_tests
fi
