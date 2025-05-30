# Preparing Infrastructure for ARO HCP Using ASO

The necessary infrastructure for deploying an ARO-HCP cluster can be provisioned using a declarative approach with [Azure Service Operator v2](https://azure.github.io/azure-service-operator/)
as part of the Cluster API Provider for Azure. In the following steps, we will create the required Azure resources,
including a Resource Group, Network Security Group, Virtual Network (VNet), Subnet, and a User Assigned Managed Identity.

Note: This document was created based on [Creating an HCP via Cluster Service](https://github.com/Azure/ARO-HCP/blob/main/cluster-service/cluster-creation.md)  

## Prerequisites

We expect the following:

* Docker or Podman with `kind` cluster is being used OR Openshift cluster v4.18 or Later  
* The following tools are installed:  
  * `az` CLI (or a `sp.json` file is already created), see [Install the Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
  * `oc` - see [OpenShift CLI (oc)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc)
  * `helm` – also required for setting up the infrastructure using the declarative approach
* Ensure you have access to the RH Azure tenant:
  * **RH account**: You need to have a Red Hat account to access the Red Hat Azure tenant (`redhat0.onmicrosoft.com`) where personal DEV environments are created
  * **Subscription access**: You need access to the `ARO Hosted Control Planes (EA Subscription 1)` subscription in the Red Hat Azure tenant. Consult the [ARO HCP onboarding guide](https://docs.google.com/document/d/1KUZSLknIkSd6usFPe_OcEYWJyW6mFeotc2lIsLgE3JA/)
  * `az login` with your Red Hat account

1. Create azure account service principal and store it in json file sp.json as follow
```bash
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
```
2. Install cert-manager using a Helm chart
This is required for non-OCP clusters, as OCP clusters include a different built-in cert-manager.
```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true
````
3. Install ASO2 using a Helm chart 
```bash
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
```
4. Deploy the AZURE secret:
```bash
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
```
## Creating infrastructure for ARO-HCP clusters
5. Then we can start such a deplouyment:
```bash
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
```
6. Then we can check the result:
```bash
oc describe resourcegroup/$NAME_PREFIX-resgroup
```
The result should be:
```
Name:         aro-hcp-resgroup
Namespace:    default
Labels:       <none>
Annotations:  serviceoperator.azure.com/latest-reconciled-generation: 1
              serviceoperator.azure.com/operator-namespace: azureserviceoperator-system
              serviceoperator.azure.com/resource-id: /subscriptions/1d3378d3-5a3f-4712-85a1-2485495dfc4b/resourceGroups/aro-hcp-resgroup
API Version:  resources.azure.com/v1api20200601
Kind:         ResourceGroup
Metadata:
  Creation Timestamp:  2025-05-14T13:42:50Z
  Finalizers:
    serviceoperator.azure.com/finalizer
  Generation:        1
  Resource Version:  2240
  UID:               a2322e73-b56f-44de-845a-94ead13549a4
Spec:
  Azure Name:  aro-hcp-resgroup
  Location:    eastus
Status:
  Conditions:
    Last Transition Time:  2025-05-14T13:42:54Z
    Observed Generation:   1
    Reason:                Succeeded
    Status:                True
    Type:                  Ready
  Id:                      /subscriptions/1d3378d3-5a3f-4712-85a1-2485495dfc4b/resourceGroups/aro-hcp-resgroup
  Location:                eastus
  Name:                    aro-hcp-resgroup
  Properties:
    Provisioning State:  Succeeded
  Tags:
    Created At:  2025-05-14T13:42:52.1436530Z
  Type:          Microsoft.Resources/resourceGroups
Events:
  Type    Reason               Age                From                     Message
  ----    ------               ----               ----                     -------
  Normal  CredentialFrom       22s (x2 over 22s)  resources_resourcegroup  Using credential from "default/aso-credential"
  Normal  BeginCreateOrUpdate  19s                resources_resourcegroup  Successfully sent resource to Azure with ID "/subscriptions/1d3378d3-5a3f-4712-85a1-2485495dfc4b/resourceGroups/aro-hcp-resgroup"
```
