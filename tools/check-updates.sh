#!/bin/bash
# check-updates.sh - Check for newer versions of pinned images

set -euo pipefail

VERSIONS_FILE="${1:-versions.env}"

if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "❌ ERROR: $VERSIONS_FILE not found"
    exit 1
fi

echo "🔍 Checking for image updates..."
source "$VERSIONS_FILE"

# Function to get latest tag from Docker Hub API (simplified)
check_image_updates() {
    local current_image="$1"
    local image_name=$(echo "$current_image" | cut -d: -f1)
    local current_tag=$(echo "$current_image" | cut -d: -f2)
    
    echo "📦 $image_name:$current_tag"
    
    # For demo purposes - in practice you'd query registry APIs
    case "$image_name" in
        "splunk/splunk")
            echo "   ℹ️  Check: https://hub.docker.com/r/splunk/splunk/tags"
            ;;
        "splunk/universalforwarder")
            echo "   ℹ️  Check: https://hub.docker.com/r/splunk/universalforwarder/tags"
            ;;
        "prom/prometheus")
            echo "   ℹ️  Check: https://hub.docker.com/r/prom/prometheus/tags"
            echo "   💡 Latest releases: https://github.com/prometheus/prometheus/releases"
            ;;
        "grafana/grafana")
            echo "   ℹ️  Check: https://hub.docker.com/r/grafana/grafana/tags"
            echo "   💡 Latest releases: https://github.com/grafana/grafana/releases"
            ;;
    esac
}

echo ""
check_image_updates "$SPLUNK_IMAGE"
echo ""
check_image_updates "$UF_IMAGE" 
echo ""
check_image_updates "$PROM_IMAGE"
echo ""
check_image_updates "$GRAFANA_IMAGE"

echo ""
echo "💡 Pro tip: Run 'docker pull <image>' to check if newer versions exist"
echo "💡 Consider automating updates with Renovate or Dependabot"