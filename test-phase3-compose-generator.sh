#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# test-phase3-compose-generator.sh
# Test script for Phase 3 compose generation rewrite
# ==============================================================================


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Phase 3 Compose Generator Test ==="

# Load dependencies
source lib/core.sh
source versions.env
source lib/compose-config.sh
source lib/compose-generator-v2.sh

# Test configuration
export ENABLE_SPLUNK=true
export ENABLE_MONITORING=true
export INDEXER_COUNT=2
export SEARCH_HEAD_COUNT=1
export SPLUNK_CLUSTER_MODE=cluster

echo "Environment variables set:"
echo "  ENABLE_SPLUNK=$ENABLE_SPLUNK"
echo "  ENABLE_MONITORING=$ENABLE_MONITORING"
echo "  INDEXER_COUNT=$INDEXER_COUNT"
echo "  SEARCH_HEAD_COUNT=$SEARCH_HEAD_COUNT"
echo "  SPLUNK_CLUSTER_MODE=$SPLUNK_CLUSTER_MODE"

# Test 1: Configuration validation
echo ""
echo "=== Test 1: Configuration Validation ==="
if validate_config; then
    echo "✅ Configuration validation passed"
else
    echo "❌ Configuration validation failed"
    exit 1
fi

# Test 2: Service enumeration
echo ""
echo "=== Test 2: Service Enumeration ==="
echo "Enabled services:"
get_enabled_services | while read -r service; do
    echo "  • $service"
done

# Test 3: Template rendering test
echo ""
echo "=== Test 3: Template Rendering ==="
test_template="lib/templates/services/splunk-indexer.yml"
if [[ -f "$test_template" ]]; then
    echo "Testing template: $test_template"
    test_config=$(get_service_config "splunk-indexer" "1")
    global_config=$(get_global_config)
    all_config=$(printf '%s\n%s' "$global_config" "$test_config")
    
    echo "Configuration variables:"
    echo "$all_config" | head -5
    echo "..."
    
    echo "Rendered template preview:"
    render_template "$test_template" "$all_config" | head -10
    echo "..."
    echo "✅ Template rendering test passed"
else
    echo "❌ Template file not found: $test_template"
    exit 1
fi

# Test 4: Full compose generation
echo ""
echo "=== Test 4: Full Compose Generation ==="
output_file="docker-compose-v2-test.yml"
rm -f "$output_file"

if generate_compose_file "$output_file"; then
    echo "✅ Compose generation completed"
    
    # Validate output
    if [[ -f "$output_file" ]]; then
        echo "Generated file size: $(wc -l < "$output_file") lines"
        echo "File preview:"
        head -20 "$output_file"
        echo "..."
        tail -10 "$output_file"
    else
        echo "❌ Output file not created"
        exit 1
    fi
else
    echo "❌ Compose generation failed"
    exit 1
fi

# Test 5: Service validation
echo ""
echo "=== Test 5: Service Validation ==="
required_services=("splunk-cm" "splunk-idx1" "splunk-idx2" "splunk-sh1" "prometheus" "grafana")
for service in "${required_services[@]}"; do
    if grep -q "^${service}:" "$output_file"; then
        echo "✅ Found service: $service"
    else
        echo "❌ Missing service: $service"
        exit 1
    fi
done

# Test 6: Compare with v1 generator (if available)
echo ""
echo "=== Test 6: V1 vs V2 Comparison ==="
if [[ -f "lib/compose-generator.sh.phase2-backup" ]]; then
    echo "Generating v1 compose for comparison..."
    
    # Temporarily restore v1 generator
    cp lib/compose-generator.sh.phase2-backup lib/compose-generator-v1-temp.sh
    
    # Source v1 and generate
    if source lib/compose-generator-v1-temp.sh 2>/dev/null; then
        v1_output="docker-compose-v1-test.yml"
        rm -f "$v1_output"
        
        if generate_compose_file "$v1_output" 2>/dev/null; then
            echo "Generated v1 compose for comparison"
            v1_lines=$(wc -l < "$v1_output")
            v2_lines=$(wc -l < "$output_file")
            
            echo "Line count comparison:"
            echo "  V1: $v1_lines lines"
            echo "  V2: $v2_lines lines"
            echo "  Difference: $((v2_lines - v1_lines)) lines"
            
            # Service count comparison
            v1_services=$(grep -c '^  [a-z-].*:$' "$v1_output" || echo "0")
            v2_services=$(grep -c '^  [a-z-].*:$' "$output_file" || echo "0")
            
            echo "Service count comparison:"
            echo "  V1: $v1_services services"
            echo "  V2: $v2_services services"
            
            if [[ "$v1_services" -eq "$v2_services" ]]; then
                echo "✅ Service count matches"
            else
                echo "⚠️  Service count differs"
            fi
        else
            echo "⚠️  Could not generate v1 compose for comparison"
        fi
    else
        echo "⚠️  Could not load v1 generator for comparison"
    fi
    
    # Cleanup
    rm -f lib/compose-generator-v1-temp.sh "$v1_output"
else
    echo "⚠️  V1 backup not found, skipping comparison"
fi

echo ""
echo "=== Phase 3 Test Results ==="
echo "✅ All core tests passed"
echo "📊 Generated compose file: $output_file"
echo "🎯 Phase 3 template-based generation working correctly"

# Cleanup test files
read -p "Delete test files? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f docker-compose-*-test.yml
    echo "Test files cleaned up"
fi
