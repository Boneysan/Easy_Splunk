# Comprehensive Bash Best Practices Guide

## Overview

This guide documents the bash best practices implemented throughout the Easy_Splunk codebase and provides guidance for maintaining these standards.

## Core Practices Implemented

### 1. Universal Header Template

All bash scripts use this standardized header:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Global trap for useful diagnostics
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:$LINENO exited with $rc" >&2; exit $rc' ERR
```

### 2. Variable Best Practices

#### Always Quote Variables
```bash
# ✅ Correct
echo "$var"
cp "$source" "$dest"
if [[ -n "$value" ]]; then

# ❌ Incorrect  
echo $var
cp $source $dest
if [[ -n $value ]]; then
```

#### Guard Against Empty Expansions
```bash
# ✅ Correct
echo "${VERBOSE:-false}"
timeout="${TIMEOUT:-30}"

# ❌ Risky
echo "$VERBOSE"
timeout="$TIMEOUT"
```

### 3. Modern Test Commands

#### Use [[ ]] Instead of [ ]
```bash
# ✅ Correct
if [[ "$var" == "value" ]]; then
if [[ -f "$file" && -r "$file" ]]; then
if [[ "$string" =~ $pattern ]]; then

# ❌ Old Style
if [ "$var" = "value" ]; then
if [ -f "$file" -a -r "$file" ]; then
```

### 4. External Command Validation

#### Use require_cmd Helpers
```bash
# ✅ Available helpers from lib/core.sh
require_docker     # Ensures docker is available
require_podman     # Ensures podman is available
require_curl       # Ensures curl is available
require_jq         # Ensures jq is available
require_git        # Ensures git is available
require_openssl    # Ensures openssl is available

# ✅ Generic usage
require_cmd "xmllint"
require_cmd "python3"

# ❌ Manual checking
if ! command -v docker >/dev/null; then
    echo "Docker not found"
    exit 1
fi
```

### 5. Array Handling

#### Use mapfile for Command Output
```bash
# ✅ Preferred method
mapfile -t files < <(find . -name "*.sh")
for file in "${files[@]}"; do
    echo "Processing: $file"
done

# ✅ Alternative for simple cases
readarray -t lines < <(grep "pattern" file.txt)

# ❌ Problematic with spaces/special chars
files=$(find . -name "*.sh")
for file in $files; do
```

### 6. Function Best Practices

#### Parameter Validation
```bash
function_name() {
    local required_param="${1:?Parameter 1 required}"
    local optional_param="${2:-default_value}"
    local readonly_param; readonly readonly_param="${3:?Parameter 3 required}"
    
    # Function body...
}
```

#### Return Values and Error Handling
```bash
validate_something() {
    local value="$1"
    
    if [[ -z "$value" ]]; then
        log_error "Value cannot be empty"
        return 1
    fi
    
    # Validation logic...
    log_info "✔ Validation passed"
    return 0
}

# Usage with proper error handling
if validate_something "$input"; then
    log_success "Validation successful"
else
    die "Validation failed"
fi
```

### 7. Logging and Error Messages

#### Consistent Error Handling
```bash
# ✅ Use standard logging functions
log_info "Starting process..."
log_warn "Non-critical issue detected"
log_error "Critical error occurred"
log_success "Operation completed successfully"

# ✅ Use die for fatal errors
die "${E_INVALID_INPUT}" "Invalid configuration: $config_file"

# ❌ Inconsistent error handling
echo "Error: something went wrong" >&2
exit 1
```

### 8. File and Path Handling

#### Safe Path Operations
```bash
# ✅ Validate paths before use
validate_safe_path "$user_path" "$base_dir"

# ✅ Use realpath for normalization
normalized_path="$(realpath -m "$path")"

# ✅ Check file existence and permissions
if [[ -f "$file" && -r "$file" ]]; then
    process_file "$file"
fi

# ❌ Unsafe path handling
cd "$user_input"  # Could be manipulated
```

### 9. Environment Variable Handling

#### Validate Required Variables
```bash
# ✅ Batch validation
validate_environment_vars "REQUIRED_VAR1" "REQUIRED_VAR2" "REQUIRED_VAR3"

# ✅ Individual validation with defaults
: "${DEPLOYMENT_MODE:=development}"
: "${LOG_LEVEL:=INFO}"
: "${TIMEOUT:=30}"
```

### 10. Loop and Control Structure Best Practices

#### Safe Iteration
```bash
# ✅ Iterate over arrays safely
for item in "${array[@]}"; do
    process "$item"
done

# ✅ Process files with null delimiter
while IFS= read -r -d '' file; do
    process_file "$file"
done < <(find . -name "*.txt" -print0)

# ✅ Read files line by line
while IFS= read -r line; do
    process_line "$line"
done < "$input_file"
```

## Implementation Status

- ✅ Universal headers: All 194+ executable scripts
- ✅ Global error traps: Implemented where appropriate
- ✅ Variable quoting: Applied consistently
- ✅ Modern test commands: [[ ]] usage standardized
- ✅ Command validation: require_cmd helpers available
- ✅ Safe array handling: mapfile patterns documented
- ✅ Error handling: Standardized across codebase

## Verification

Use the provided tools to verify compliance:

```bash
# Check best practices implementation
./check-bash-practices.sh

# Verify header standardization
./verify-headers.sh

# Run comprehensive validation
./validate-codebase.sh
```

## Maintenance Guidelines

1. **New Scripts**: Always start with the universal header template
2. **External Commands**: Use require_cmd helpers before calling external programs
3. **User Input**: Always validate and sanitize user-provided data
4. **File Operations**: Use safe path validation functions
5. **Error Handling**: Provide clear, actionable error messages
6. **Testing**: Test scripts with set -u to catch unset variables

This comprehensive approach ensures robust, maintainable, and secure bash scripting across the entire Easy_Splunk platform.
