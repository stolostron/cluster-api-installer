#!/bin/bash
#
# Creates a pre-provisioned MSI resource group with bare managed identities
# for CAPZ CI tests. Role assignments are created at test time by ASO via
# aro-template-roleassignments.yaml, not pre-provisioned here.
#
# Usage:
#   ./create-ci-msi-pool.sh <resource-group> [subscription] [region]
#
# Example:
#   ./create-ci-msi-pool.sh capi-test-msi-001-rg
#   ./create-ci-msi-pool.sh capi-test-msi-001-rg b23756f7-4594-40a3-980f-10bb6168fc20 uksouth # for ARO HCP - Misc Testing (EA Subscription)

#
set -euo pipefail

RG="${1:?Usage: $0 <resource-group> [subscription] [region]}"
SUBSCRIPTION="${2:-b23756f7-4594-40a3-980f-10bb6168fc20}"
REGION="${3:-uksouth}"

SUB_ARGS=()
if [ -n "$SUBSCRIPTION" ]; then
    SUB_ARGS=(--subscription "$SUBSCRIPTION")
fi

SUBSCRIPTION_ID=$(az account show --query id -o tsv "${SUB_ARGS[@]}")
echo "Subscription: $SUBSCRIPTION_ID"
echo "Resource group: $RG"
echo "Region: $REGION"

IDENTITIES=(
    cluster-api-azure
    control-plane
    cloud-controller-manager
    ingress
    disk-csi-driver
    file-csi-driver
    image-registry
    cloud-network-config
    kms
    dp-disk-csi-driver
    dp-file-csi-driver
    dp-image-registry
    service
)

# --- Create resource group ---
echo ""
echo "=== Creating resource group ==="
az group create --name "$RG" --location "$REGION" "${SUB_ARGS[@]}" -o none
echo "  ✓ $RG"

# --- Create managed identities ---
echo ""
echo "=== Creating managed identities ==="
for id in "${IDENTITIES[@]}"; do
    PRINCIPAL_ID=$(az identity create \
        --name "$id" \
        --resource-group "$RG" \
        --location "$REGION" \
        "${SUB_ARGS[@]}" \
        --query principalId -o tsv)
    echo "  ✓ $id  ($PRINCIPAL_ID)"
done

echo ""
echo "=== Done ==="
echo ""
echo "To use in CI, set:"
echo "  export MSI_RESOURCEGROUPNAME=$RG"
echo ""
echo "Role assignments will be created at test time by ASO via"
echo "aro-template-roleassignments.yaml (scoped to per-run VNet/Subnet/NSG)."
