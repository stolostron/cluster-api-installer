#!/bin/bash
# Script to verify the GitHub release has required files

RELEASE_URL="https://github.com/stolostron/cluster-api-provider-azure/releases/tag/v1.22.0-mce-217"
RELEASE_API_URL="https://api.github.com/repos/stolostron/cluster-api-provider-azure/releases/tags/v1.22.0-mce-217"

echo "Checking GitHub release: v1.22.0-mce-217"
echo "=========================================="
echo ""

# Check if release exists
if ! curl -sf "$RELEASE_API_URL" > /dev/null; then
    echo "❌ ERROR: Release not found or not accessible"
    exit 1
fi

echo "✅ Release exists and is accessible"
echo ""

# Check for required files
echo "Checking for required files:"
ASSETS=$(curl -s "$RELEASE_API_URL" | jq -r '.assets[].name')

if echo "$ASSETS" | grep -q "metadata.yaml"; then
    echo "  ✅ metadata.yaml found"
else
    echo "  ❌ metadata.yaml NOT found (REQUIRED)"
    exit 1
fi

if echo "$ASSETS" | grep -q "infrastructure-components.yaml"; then
    echo "  ✅ infrastructure-components.yaml found"
else
    echo "  ❌ infrastructure-components.yaml NOT found (REQUIRED)"
    exit 1
fi

echo ""
echo "All required files present!"
echo ""
echo "Release URL: $RELEASE_URL"
