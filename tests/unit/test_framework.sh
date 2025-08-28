#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$nt

# ==============================================================================
# tests/unit/test_framework.sh
# Unit test framework for Easy_Splunk
# ==============================================================================

# Initialize test counters
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

# Terminal colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly NC='\033[0m' # No Color

# Test assertion functions
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}✅ PASS: $message${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}❌ FAIL: $message${NC}"
        echo -e "${RED}   Expected: $expected${NC}"
        echo -e "${RED}   Actual:   $actual${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_true() {
    local condition="$1"
    local message="${2:-}"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    
    if eval "$condition"; then
        echo -e "${GREEN}✅ PASS: $message${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}❌ FAIL: $message${NC}"
        echo -e "${RED}   Condition failed: $condition${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_false() {
    local condition="$1"
    local message="${2:-}"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    
    if ! eval "$condition"; then
        echo -e "${GREEN}✅ PASS: $message${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}❌ FAIL: $message${NC}"
        echo -e "${RED}   Condition unexpectedly succeeded: $condition${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File exists check}"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    
    if [[ -f "$file" ]]; then
        echo -e "${GREEN}✅ PASS: $message${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}❌ FAIL: $message${NC}"
        echo -e "${RED}   File does not exist: $file${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_dir_exists() {
    local dir="$1"
    local message="${2:-Directory exists check}"
    
    TEST_COUNT=$((TEST_COUNT + 1))
    
    if [[ -d "$dir" ]]; then
        echo -e "${GREEN}✅ PASS: $message${NC}"
        PASS_COUNT=$((PASS_COUNT + 1))
    else
        echo -e "${RED}❌ FAIL: $message${NC}"
        echo -e "${RED}   Directory does not exist: $dir${NC}"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

# Test suite runner
run_test_suite() {
    echo "Running test suite..."
    
    # Source all test files
    for test_file in tests/unit/test_*.sh; do
        if [[ "$test_file" != "$(basename "$0")" ]]; then
            echo "Running tests from $test_file..."
            source "$test_file"
        fi
    done
    
    # Print test summary
    echo "----------------------------------------"
    echo "Test Summary:"
    echo "----------------------------------------"
    echo "Total Tests: $TEST_COUNT"
    echo -e "${GREEN}Passed: $PASS_COUNT${NC}"
    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}Failed: $FAIL_COUNT${NC}"
    else
        echo "Failed: 0"
    fi
    echo "----------------------------------------"
    
    # Exit with appropriate status
    [[ $FAIL_COUNT -eq 0 ]] && exit 0 || exit 1
}

# Run tests if this script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_test_suite
fi
