export AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
if [ ! -f sp.json ] ; then
    let "randomIdentifier=$RANDOM*$RANDOM"
    servicePrincipalName="msdocs-sp-$randomIdentifier"
    roleName="Contributor"
    echo "Creating SP for RBAC with name $servicePrincipalName, with role $roleName and in scopes /subscriptions/$AZURE_SUBSCRIPTION_ID"
    az ad sp create-for-rbac --name $servicePrincipalName --role $roleName --scopes /subscriptions/$AZURE_SUBSCRIPTION_ID > sp.json
fi
export AZURE_TENANT_ID=$(jq -r .tenant sp.json)
export AZURE_CLIENT_ID=$(jq -r .appId sp.json)
export AZURE_CLIENT_SECRET=$(jq -r .password sp.json)
export REGION=westus3
export NAME_PREFIX=aro-hcp

# to skip do "export SKIP_CERT_MANAGER=true" before run
if [ -z "$SKIP_CERT_MANAGER" ] ; then
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
fi

# to skip do "export SKIP_ASO2_INSTALL=true" before run
if [ -z "$SKIP_ASO2_INSTALL" ] ; then


if [ -z "$USE_ASO2_HELM" ] ; then

export CLUSTER_TOPOLOGY=true
export AZURE_CLIENT_ID_USER_ASSIGNED_IDENTITY=$AZURE_CLIENT_ID # for compatibility with CAPZ v1.16 templates

# Settings needed for AzureClusterIdentity used by the AzureCluster
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"

# we need to define list of crds to install
export ADDITIONAL_ASO_CRDS='resources.azure.com/*;containerservice.azure.com/*;keyvault.azure.com/*;managedidentity.azure.com/*;eventhub.azure.com/*;network.azure.com/*;authorization.azure.com/*'

# Create a secret to include the password of the Service Principal identity created in Azure
# This secret will be referenced by the AzureClusterIdentity used by the AzureCluster
oc create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" --namespace "${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}"

# Finally, initialize the management cluster
clusterctl init --infrastructure azure
else
helm repo add aso2 https://raw.githubusercontent.com/Azure/azure-service-operator/main/v2/charts
helm repo update
helm upgrade --install --devel aso2 aso2/azure-service-operator \
        --create-namespace --wait --timeout 2m \
        --namespace=azureserviceoperator-system \
        --set azureSubscriptionID=$AZURE_SUBSCRIPTION_ID \
        --set azureTenantID=$AZURE_TENANT_ID \
        --set azureClientID=$AZURE_CLIENT_ID \
        --set useWorkloadIdentityAuth=true \
        --set crdPattern='resources.azure.com/*;containerservice.azure.com/*;keyvault.azure.com/*;managedidentity.azure.com/*;eventhub.azure.com/*;network.azure.com/*;authorization.azure.com/*'

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
 name: aso-credential
 namespace: default
stringData:
 AZURE_SUBSCRIPTION_ID: "$AZURE_SUBSCRIPTION_ID"
 AZURE_TENANT_ID: "$AZURE_TENANT_ID"
 AZURE_CLIENT_ID: "$AZURE_CLIENT_ID"
 AZURE_CLIENT_SECRET: "$AZURE_CLIENT_SECRET"
EOF
fi
fi

cat <<EOF | oc apply -f -
# Equivalent to:
# az group create --name "$NAME_PREFIX-resgroup" --location "$REGION"
# This YAML creates a Resource Group named "$NAME_PREFIX-resgroup" in the specified Azure region "$REGION".
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: $NAME_PREFIX-resgroup
  namespace: default
spec:
  location: $REGION
---
# Equivalent to:
# az network vnet create -n "$NAME_PREFIX-vnet" -g "$NAME_PREFIX-resgroup"
# This YAML creates a virtual network named "$NAME_PREFIX-vnet" in the "$NAME_PREFIX-resgroup" resource group.
apiVersion: network.azure.com/v1api20201101
kind: VirtualNetwork
metadata:
  name: $NAME_PREFIX-vnet
  namespace: default
spec:
  location: $REGION
  owner:
    name: $NAME_PREFIX-resgroup
  addressSpace:
    addressPrefixes:
      - 10.100.0.0/15
---
# Equivalent to:
# az network nsg create -n "$NAME_PREFIX-nsg" -g "$NAME_PREFIX-resgroup"
# This YAML creates a Network Security Group (NSG) named "$NAME_PREFIX-nsg" in the "${NAME_PREFIX}-resgroup" resource group.
apiVersion: network.azure.com/v1api20201101
kind: NetworkSecurityGroup
metadata:
  name: $NAME_PREFIX-nsg
  namespace: default
spec:
  location: $REGION
  owner:
    name: $NAME_PREFIX-resgroup
---
# Equivalent to:
# az network vnet subnet create -n "$NAME_PREFIX-subnet" -g "$NAME_PREFIX-resgroup" --vnet-name "$NAME_PREFIX-vnet" --network-security-group "$NAME_PREFIX-nsg"
# This YAML creates a subnet named "$NAME_PREFIX-subnet" in the "$NAME_PREFIX-vnet" virtual network and associates it with the "$NAME_PREFIX-nsg" Network Security Group.
apiVersion: network.azure.com/v1api20201101
kind: VirtualNetworksSubnet
metadata:
  name: $NAME_PREFIX-subnet
  namespace: default
spec:
  owner:
    name: $NAME_PREFIX-vnet
  addressPrefix: 10.100.76.0/24
  networkSecurityGroup: 
    reference:
      name: $NAME_PREFIX-nsg
      group: network.azure.com
      kind: NetworkSecurityGroup
EOF
USER=user1
CS_CLUSTER_NAME=cluster1
OPERATORS_UAMIS_SUFFIX_FILE=operators-uamis-suffix.txt
if [ ! -f "$OPERATORS_UAMIS_SUFFIX_FILE" ] ; then
    openssl rand -hex 3 > "$OPERATORS_UAMIS_SUFFIX_FILE"
fi
OPERATORS_UAMIS_SUFFIX=$(cat "$OPERATORS_UAMIS_SUFFIX_FILE")
cat > infra-names.js <<EOF
{
    "REGION": "$REGION",
    "USER": "$USER",
    "CS_CLUSTER_NAME": "$CS_CLUSTER_NAME",
    "NSG": "$NAME_PREFIX-nsg",
    "RESOURCEGROUPNAME": "$NAME_PREFIX-resgroup",
    "VNET": "$NAME_PREFIX-vnet",
    "SUBNET": "$NAME_PREFIX-subnet",
    "OPERATORS_UAMIS_SUFFIX": "$OPERATORS_UAMIS_SUFFIX"
}
EOF
> AroHcpUserAssignedIdentity.yaml
for IDENTITY_NAME in \
    ${USER}-${CS_CLUSTER_NAME}-cp-control-plane-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-cluster-api-azure-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-cloud-controller-manager-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-ingress-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-disk-csi-driver-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-file-csi-driver-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-image-registry-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-cloud-network-config-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-cp-kms-${OPERATORS_UAMIS_SUFFIX} \
    \
    ${USER}-${CS_CLUSTER_NAME}-dp-disk-csi-driver-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-dp-image-registry-${OPERATORS_UAMIS_SUFFIX} \
    ${USER}-${CS_CLUSTER_NAME}-dp-file-csi-driver-${OPERATORS_UAMIS_SUFFIX} \
    \
    ${USER}-${CS_CLUSTER_NAME}-service-managed-identity-${OPERATORS_UAMIS_SUFFIX} \
; do 
cat >> AroHcpUserAssignedIdentity.yaml <<EOF
---
# Equivalent to:
# az identity create -n "$IDENTITY_NAME" -g "$NAME_PREFIX-resgroup"
# This YAML creates a managed identity named "$IDENTITY_NAME" in the "$NAME_PREFIX-resgroup" resource group.
apiVersion: managedidentity.azure.com/v1api20230131
kind: UserAssignedIdentity
metadata:
  name: $IDENTITY_NAME
  namespace: default
spec:
  location: $REGION
  owner:
    name: $NAME_PREFIX-resgroup
EOF
done
oc apply -f AroHcpUserAssignedIdentity.yaml
