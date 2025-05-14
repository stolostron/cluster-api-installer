AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
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

# to skip do "export SKIP_ASO2_INSTALL=true" before run
if [ -n "$SKIP_ASO2_INSTALL" ] ; then
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true

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

cat <<EOF | oc apply -f -
# az group create --name <resource-group> --location <location>
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: $NAME_PREFIX-resgroup
  namespace: default
spec:
  location: $REGION
---
# az network vnet create -n <vnet-name> -g <resource-group> --subnet-name <subnet-name>
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
# az network nsg create -n <nsg-name> -g <resource-group>
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
# az network vnet create -n <vnet-name> -g <resource-group> --subnet-name <subnet-name>
# az network vnet subnet update -g <resource-group> -n <subnet-name> --vnet-name <vnet-name> --network-security-group <nsg-name>
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
# az identity create -n ${IDENTITY_NAME} -g <resource-group>
apiVersion: managedidentity.azure.com/v1api20230131
kind: UserAssignedIdentity
metadata:
  name: ${IDENTITY_NAME}
  namespace: default
spec:
  location: $REGION
  owner:
    name: $NAME_PREFIX-resgroup
EOF
done
oc apply -f AroHcpUserAssignedIdentity.yaml
