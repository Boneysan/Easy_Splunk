#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s lastpipe 2>/dev/null || true

# Strict IFS for safer word splitting
IFS=$'\n\t'

# validate-images.sh - Simple validation for versions.env


VERSIONS_FILE="${1:-versions.env}"

if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "❌ ERROR: $VERSIONS_FILE not found"
    exit 1
fi

echo "🔍 Validating $VERSIONS_FILE..."

# Source the file
source "$VERSIONS_FILE"

# Required images
REQUIRED_IMAGES=("SPLUNK_IMAGE" "UF_IMAGE" "PROM_IMAGE" "GRAFANA_IMAGE")
errors=0

for img_var in "${REQUIRED_IMAGES[@]}"; do
    img_val="${!img_var:-}"
    
    if [[ -z "$img_val" ]]; then
        echo "❌ ERROR: $img_var is not set"
        ((errors++))
        continue
    fi
    
    # Check format (repo:tag or repo@digest)
    if [[ ! "$img_val" =~ ^[a-zA-Z0-9._/-]+(:.*|@sha256:[a-f0-9]{64})$ ]]; then
        echo "❌ ERROR: $img_var has invalid format: $img_val"
        ((errors++))
        continue
    fi
    
    # Warn about 'latest' tag
    if [[ "$img_val" =~ :latest$ ]]; then
        echo "⚠️  WARNING: $img_var uses 'latest' tag (not recommended)"
    fi
    
    echo "✅ $img_var=$img_val"
done

# Check Splunk version alignment
splunk_ver=$(echo "$SPLUNK_IMAGE" | sed -n 's/.*:\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')
uf_ver=$(echo "$UF_IMAGE" | sed -n 's/.*:\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

if [[ -n "$splunk_ver" && -n "$uf_ver" && "$splunk_ver" != "$uf_ver" ]]; then
    echo "⚠️  WARNING: Splunk Enterprise ($splunk_ver) and UF ($uf_ver) versions don't match"
fi

# Check compose project name
if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    echo "✅ COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}"
else
    echo "ℹ️  COMPOSE_PROJECT_NAME not set (will use directory name)"
fi

if [[ $errors -eq 0 ]]; then
    echo ""
    echo "🎉 All validations passed!"
    exit 0
else
    echo ""
    echo "💥 Found $errors validation errors"
    exit 1
