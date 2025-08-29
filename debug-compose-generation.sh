#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# ==============================================================================
# debug-compose-generation.sh
# Debug script to test compose generation with proper environment setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Debug Compose Generation ==="
echo "Working directory: $(pwd)"

# Set up environment for Splunk generation
echo "Setting up environment variables..."
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

# Check if compose generator exists
if [[ ! -f "lib/compose-generator.sh" ]]; then
    echo "ERROR: lib/compose-generator.sh not found"
    exit 1
fi

echo "Loading libraries in correct order..."

# Load core first (provides basic functions)
echo "Loading core.sh..."
source lib/core.sh 2>/dev/null || echo "Warning: core.sh failed to load"

# Add fallback functions that might be missing
echo "Adding fallback functions..."
if ! type begin_step &>/dev/null; then
    begin_step() { log_info "Starting: $1"; }
fi
if ! type complete_step &>/dev/null; then
    complete_step() { log_info "Completed: $1"; }
fi
if ! type url &>/dev/null; then
    url() { echo "$1"; }  # Simple fallback
fi
if ! type safe_path &>/dev/null; then
    safe_path() { echo "$1"; }  # Simple fallback
fi
if ! type validate_environment_vars &>/dev/null; then
    validate_environment_vars() {
        log_info "Validating environment variables..."
        # Simple validation - just check if ENABLE_SPLUNK is set
        if [[ -z "${ENABLE_SPLUNK:-}" ]]; then
            log_error "ENABLE_SPLUNK is not set"
            return 1
        fi
        return 0
    }
fi
if ! type validate_splunk_cluster_size &>/dev/null; then
    validate_splunk_cluster_size() {
        local indexer_count="$1"
        local search_head_count="$2"
        log_info "Validating Splunk cluster size: ${indexer_count} indexers, ${search_head_count} search heads"
        # Basic validation
        if [[ "$indexer_count" -lt 1 ]]; then
            log_error "INDEXER_COUNT must be at least 1"
            return 1
        fi
        if [[ "$search_head_count" -lt 1 ]]; then
            log_error "SEARCH_HEAD_COUNT must be at least 1"
            return 1
        fi
        return 0
    }
fi
if ! type validate_image_references &>/dev/null; then
    validate_image_references() {
        local compose_file="$1"
        log_info "Validating image references in: $compose_file"
        # Simple validation - just check if file exists and has some content
        if [[ ! -f "$compose_file" ]]; then
            log_error "Compose file does not exist: $compose_file"
            return 1
        fi
        if ! grep -q "image:" "$compose_file"; then
            log_error "No image references found in compose file"
            return 1
        fi
        return 0
    }
fi

# Load compose generator (it will handle its own dependencies)
echo "Loading compose-generator.sh..."
source lib/compose-generator.sh || {
    echo "ERROR: Failed to load compose generator"
    exit 1
}

echo "Checking if generate_compose_file function exists..."
if ! declare -F generate_compose_file >/dev/null 2>&1; then
    echo "ERROR: generate_compose_file function not found"
    exit 1
fi

echo "Generating test compose file..."
rm -f docker-compose-test.yml
generate_compose_file docker-compose-test.yml || {
    echo "ERROR: Compose generation failed"
    exit 1
}

echo "=== Generated compose file preview ==="
head -50 docker-compose-test.yml

echo ""
echo "=== Checking for Splunk services ==="
if grep -q "splunk-idx" docker-compose-test.yml; then
    echo "✅ SUCCESS: Found Splunk indexer services"
else
    echo "❌ FAILED: No Splunk indexer services found"
fi

if grep -q "splunk-sh" docker-compose-test.yml; then
    echo "✅ SUCCESS: Found Splunk search head services"
else
    echo "❌ FAILED: No Splunk search head services found"
fi

if grep -q "splunk-cm" docker-compose-test.yml; then
    echo "✅ SUCCESS: Found Splunk cluster master service"
else
    echo "❌ FAILED: No Splunk cluster master service found"
fi

if grep -q "app:" docker-compose-test.yml; then
    echo "⚠️  WARNING: Found generic app service (should not be present)"
else
    echo "✅ SUCCESS: No generic app service found"
fi

echo ""
echo "=== Debug complete ==="
echo "Test compose file saved as: docker-compose-test.yml"
