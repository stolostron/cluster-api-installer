#!/bin/bash
set -e

# When CAPZ_ASO_VERSION is set, download ASO release artifacts at that version
# and rebuild config/aso/kustomization.yaml and crds.yaml, replacing whatever
# CAPZ shipped. This decouples ASO CRD/webhook versions from the CAPZ branch.

[ -z "${CAPZ_ASO_VERSION}" ] && exit 0

CAPZ_ASO_ORGREPO="${CAPZ_ASO_ORGREPO:-https://github.com/stolostron}"
ASO_RELEASE_URL="${CAPZ_ASO_ORGREPO}/azure-service-operator/releases/download/${CAPZ_ASO_VERSION}"
ASO_BUNDLE_URL="${ASO_RELEASE_URL}/azureserviceoperator_${CAPZ_ASO_VERSION}.yaml"
ASO_CRDS_URL="${ASO_RELEASE_URL}/azureserviceoperator_customresourcedefinitions_${CAPZ_ASO_VERSION}.yaml"

CAPZ_ASO_CRDS="${CAPZ_ASO_CRDS:-\
    bastionhosts.network.azure.com \
    extensions.kubernetesconfiguration.azure.com \
    fleetsmembers.containerservice.azure.com \
    hcpopenshiftclusters.redhatopenshift.azure.com \
    hcpopenshiftclustersexternalauths.redhatopenshift.azure.com \
    hcpopenshiftclustersnodepools.redhatopenshift.azure.com \
    maintenanceconfigurations.containerservice.azure.com \
    managedclusters.containerservice.azure.com \
    managedclustersagentpools.containerservice.azure.com \
    natgateways.network.azure.com \
    networksecuritygroups.network.azure.com \
    privateendpoints.network.azure.com \
    resourcegroups.resources.azure.com \
    roleassignments.authorization.azure.com \
    userassignedidentities.managedidentity.azure.com \
    vaults.keyvault.azure.com \
    virtualnetworks.network.azure.com \
    virtualnetworkssubnets.network.azure.com \
}"

echo "=== hack.sh: rebuilding ASO resources from release ${CAPZ_ASO_VERSION} ==="

# Update the release URL in config/aso/kustomization.yaml
echo "Updating release URL to ${CAPZ_ASO_VERSION}"
sed -i 's|https://github.com/.*/azure-service-operator/releases/download/.*/azureserviceoperator_.*\.yaml|'"${ASO_BUNDLE_URL}"'|' \
    config/aso/kustomization.yaml

# Update the ASO image tag in config/aso/kustomization.yaml
sed -i 's|quay.io/capz/azureserviceoperator:[^ ]*|quay.io/capz/azureserviceoperator:'"${CAPZ_ASO_VERSION}"'|g' \
    config/aso/kustomization.yaml

# Download and filter CRDs
echo "Downloading ASO CRDs from ${ASO_CRDS_URL}"
ASO_CRDS_FULL=$(mktemp)
curl -fSsL "${ASO_CRDS_URL}" > "${ASO_CRDS_FULL}"

FILTER_EXPR=""
for name in ${CAPZ_ASO_CRDS}; do
    [ -n "${FILTER_EXPR}" ] && FILTER_EXPR="${FILTER_EXPR} or "
    FILTER_EXPR="${FILTER_EXPR}.metadata.name == \"${name}\""
done

ASO_CRDS_FILE="config/aso/crds.yaml"
${YQ} e ". | select(${FILTER_EXPR})" "${ASO_CRDS_FULL}" \
    | sed 's/\$\$/$$$$/g' > "${ASO_CRDS_FILE}"
rm -f "${ASO_CRDS_FULL}"

echo "Wrote $(grep -c '^kind: CustomResourceDefinition' "${ASO_CRDS_FILE}") CRDs to ${ASO_CRDS_FILE}"
echo "=== hack.sh: ASO resources rebuilt from release ${CAPZ_ASO_VERSION} ==="
