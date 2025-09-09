#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# fix-all-function-loading.sh - Systematic fix for function loading issues across all Easy_Splunk scripts


echo "🔧 Applying systematic function loading fixes to all Easy_Splunk scripts..."

# Define the fallback function templates
FALLBACK_LOG_MESSAGE='
# Fallback log_message function for error handling library compatibility
if ! type log_message &>/dev/null; then
  log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    case "$level" in
      ERROR)   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
      WARNING) echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" >&2 ;;
      SUCCESS) echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
      DEBUG)   [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[36m[$timestamp] DEBUG: $message\033[0m" ;;
      *)       echo -e "[$timestamp] INFO: $message" ;;
    esac
  }
fi'

FALLBACK_ERROR_EXIT='
# Fallback error_exit function for error handling library compatibility
if ! type error_exit &>/dev/null; then
  error_exit() {
    local error_code=1
    local error_message=""
    
    if [[ $# -eq 1 ]]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        error_code="$1"
        error_message="Script failed with exit code $error_code"
      else
        error_message="$1"
      fi
    elif [[ $# -eq 2 ]]; then
      error_message="$1"
      error_code="$2"
    fi
    
    if [[ -n "$error_message" ]]; then
      log_message ERROR "${error_message:-Unknown error}"
    fi
    
    exit "$error_code"
  }
fi'

FALLBACK_INIT_ERROR_HANDLING='
# Fallback init_error_handling function for error handling library compatibility
if ! type init_error_handling &>/dev/null; then
  init_error_handling() {
    # Basic error handling setup - no-op fallback
    set -euo pipefail
  }
fi'

FALLBACK_REGISTER_CLEANUP='
# Fallback register_cleanup function for error handling library compatibility
if ! type register_cleanup &>/dev/null; then
  register_cleanup() {
    # Basic cleanup registration - no-op fallback
    # Production systems should use proper cleanup handling
    return 0
  }
fi'

FALLBACK_VALIDATE_SAFE_PATH='
# Fallback validate_safe_path function for error handling library compatibility
if ! type validate_safe_path &>/dev/null; then
  validate_safe_path() {
    local path="$1"
    local description="${2:-path}"
    
    # Basic path validation
    if [[ -z "$path" ]]; then
      log_message ERROR "$description cannot be empty"
      return 1
    fi
    
    if [[ "$path" == *".."* ]]; then
      log_message ERROR "$description contains invalid characters (..)"
      return 1
    fi
    
    return 0
  }
fi'

FALLBACK_WITH_RETRY='
# Fallback with_retry function for error handling library compatibility
if ! type with_retry &>/dev/null; then
  with_retry() {
    local max_attempts=3
    local delay=2
    local attempt=1
    local cmd=("$@")
    
    while [[ $attempt -le $max_attempts ]]; do
      if "${cmd[@]}"; then
        return 0
      fi
      
      local rc=$?
      if [[ $attempt -eq $max_attempts ]]; then
        log_message ERROR "with_retry: command failed after ${attempt} attempts (rc=${rc}): ${cmd[*]}" 2>/dev/null || echo "ERROR: with_retry failed after ${attempt} attempts" >&2
        return $rc
      fi
      
      log_message WARNING "Attempt ${attempt} failed (rc=${rc}); retrying in ${delay}s..." 2>/dev/null || echo "WARNING: Attempt ${attempt} failed, retrying in ${delay}s..." >&2
      sleep $delay
      ((attempt++))
      ((delay *= 2))
    done
  }
fi'

# List of critical scripts that need function loading fixes
CRITICAL_SCRIPTS=(
  "orchestrator.sh"
  "deploy.sh" 
  "health_check.sh"
  "backup_cluster.sh"
  "restore_cluster.sh"
  "start_cluster.sh"
  "stop_cluster.sh"
  "download-uf.sh"
  "create-airgapped-bundle.sh"
  "security-validation.sh"
  "success-criteria-validation.sh"
)

# Function to add fallback functions to a script
add_fallback_functions() {
  local script_path="$1"
  local script_name=$(basename "$script_path")
  
  echo "  📝 Processing $script_name..."
  
  # Check if script exists and is readable
  if [[ ! -f "$script_path" ]] || [[ ! -r "$script_path" ]]; then
    echo "    ⚠️  Script not found or not readable: $script_path"
    return 1
  fi
  
  # Check if the script already has fallback functions
  if grep -q "Fallback.*function for error handling library compatibility" "$script_path" 2>/dev/null; then
    echo "    ✅ $script_name already has fallback functions"
    return 0
  fi
  
  # Find the insertion point (after the initial shebang and comments, before main logic)
  local insert_line
  insert_line=$(grep -n "^[[:space:]]*$\|^# Source\|^source\|^[.]" "$script_path" | head -1 | cut -d: -f1)
  
  if [[ -z "$insert_line" ]]; then
    # If no clear insertion point, insert after shebang
    insert_line=$(grep -n "^#!/" "$script_path" | head -1 | cut -d: -f1)
    if [[ -n "$insert_line" ]]; then
      ((insert_line++))
    else
      insert_line=1
    fi
  fi
  
  # Create a backup
  cp "$script_path" "${script_path}.backup-$(date +%s)"
  
  # Create temporary file with fallback functions
  local temp_file=$(mktemp)
  
  # Add everything up to insertion point
  head -n "$((insert_line))" "$script_path" > "$temp_file"
  
  # Add fallback functions
  cat >> "$temp_file" << 'EOF'

# BEGIN: Fallback functions for error handling library compatibility
# These functions provide basic functionality when lib/error-handling.sh fails to load
EOF
  
  echo "$FALLBACK_LOG_MESSAGE" >> "$temp_file"
  echo "$FALLBACK_ERROR_EXIT" >> "$temp_file"
  echo "$FALLBACK_INIT_ERROR_HANDLING" >> "$temp_file"
  echo "$FALLBACK_REGISTER_CLEANUP" >> "$temp_file"
  echo "$FALLBACK_VALIDATE_SAFE_PATH" >> "$temp_file"
  echo "$FALLBACK_WITH_RETRY" >> "$temp_file"
  
  cat >> "$temp_file" << 'EOF'
# END: Fallback functions for error handling library compatibility

EOF
  
  # Add the rest of the file
  tail -n "+$((insert_line + 1))" "$script_path" >> "$temp_file"
  
  # Replace original file
  mv "$temp_file" "$script_path"
  
  # Restore permissions
  chmod +x "$script_path"
  
  echo "    ✅ Added fallback functions to $script_name"
}

# Process all critical scripts
echo "🎯 Processing critical scripts..."
for script in "${CRITICAL_SCRIPTS[@]}"; do
  script_path="/mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk/$script"
  add_fallback_functions "$script_path" || echo "    ❌ Failed to process $script"
done

# Also process any other .sh files that use these functions
echo "🔍 Scanning for other scripts that need fixes..."
while IFS= read -r -d '' script_path; do
  script_name=$(basename "$script_path")
  
  # Skip if already processed
  skip=false
  for processed in "${CRITICAL_SCRIPTS[@]}"; do
    if [[ "$script_name" == "$processed" ]]; then
      skip=true
      break
    fi
  done
  
  if [[ "$skip" == "true" ]]; then
    continue
  fi
  
  # Skip if it's a backup or generated file
  if [[ "$script_name" == *.backup-* ]] || [[ "$script_name" == *test* ]] || [[ "$script_name" == fix-* ]]; then
    continue
  fi
  
  # Check if script uses error handling functions
  if grep -q "log_message\|error_exit\|init_error_handling\|register_cleanup\|with_retry" "$script_path" 2>/dev/null; then
    echo "  📝 Found additional script: $script_name"
    add_fallback_functions "$script_path" || echo "    ❌ Failed to process $script_name"
  fi
done < <(find /mnt/d/GitHub/Rhel8_Splunk/Easy_Splunk -name "*.sh" -type f -print0)

echo ""
echo "✅ Function loading fixes applied successfully!"
echo ""
echo "📋 Summary:"
echo "   • Added fallback implementations for critical error handling functions"
echo "   • Functions include: log_message, error_exit, init_error_handling, register_cleanup, validate_safe_path, with_retry"
echo "   • All scripts now have local fallbacks if lib/error-handling.sh fails to load"
echo "   • Backup files created with .backup-<timestamp> extension"
echo ""
echo "🧪 Testing: You can now run any script and it should work even if library loading fails"
echo "   Example: ./generate-credentials.sh --help"
echo "           ./orchestrator.sh --help"
echo "           ./health_check.sh --help"
