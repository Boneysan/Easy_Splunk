#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# Header verification script
# Checks that key scripts have the universal bash header

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Universal Bash Header Verification ==="
echo "Checking key executable scripts for proper headers..."
echo

# Key scripts to verify
key_scripts=(
    "deploy.sh"
    "orchestrator.sh" 
    "install-prerequisites.sh"
    "start_cluster.sh"
    "stop_cluster.sh"
    "health_check.sh"
    "resolve-digests.sh"
    "test-security-validation.sh"
    "lib/core.sh"
    "lib/error-handling.sh"
    "lib/selinux-preflight.sh"
    "lib/image-validator.sh"
    "lib/compose-validation.sh"
)

check_script_header() {
    local script="$1"
    local full_path="$SCRIPT_DIR/$script"
    
    if [[ ! -f "$full_path" ]]; then
        echo "❌ $script - File not found"
        return 1
    fi
    
    if [[ ! -x "$full_path" ]]; then
        echo "⚠️  $script - Not executable"
        return 1
    fi
    
    # Check for universal header components
    local has_shebang=false
    local has_strict_mode=false
    local has_lastpipe=false
    local has_ifs=false
    
    while IFS= read -r line; do
        if [[ "$line" == *"#!/usr/bin/env bash"* ]]; then has_shebang=true; fi
        if [[ "$line" == *"set -Eeuo pipefail"* ]]; then has_strict_mode=true; fi
        if [[ "$line" == *"shopt -s lastpipe"* ]]; then has_lastpipe=true; fi
        if [[ "$line" == *"IFS="* ]]; then has_ifs=true; fi
    done < <(head -10 "$full_path")
    
    if [[ "$has_shebang" == true && "$has_strict_mode" == true && "$has_lastpipe" == true && "$has_ifs" == true ]]; then
        echo "✅ $script - Complete universal header"
        return 0
    else
        echo "⚠️  $script - Incomplete header (shebang:$has_shebang strict:$has_strict_mode lastpipe:$has_lastpipe ifs:$has_ifs)"
        return 1
    fi
}

# Check all key scripts
total=0
compliant=0

for script in "${key_scripts[@]}"; do
    ((total++))
    if check_script_header "$script"; then
        ((compliant++))
    fi
done

echo
echo "=== Verification Summary ==="
echo "Scripts checked: $total"
echo "Fully compliant: $compliant"
echo "Compliance rate: $((compliant * 100 / total))%"

if [[ $compliant -eq $total ]]; then
    echo "🎉 All key scripts have the universal bash header!"
else
    echo "📝 Some scripts need manual header updates"
fi

echo
echo "Universal header format:"
echo "#!/usr/bin/env bash"
echo "set -Eeuo pipefail"
echo "shopt -s lastpipe 2>/dev/null || true"
echo ""
echo "# Strict IFS for safer word splitting"
echo "IFS=\$'\\n\\t'"
