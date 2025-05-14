# Preparing Infrastructure for ARO HCP Using ASO

We need to initialize the prerequisite infrastructure to create an ARO-HCP cluster:

* This can be done using the `az` CLI command, as shown here: [Creating an HCP via Cluster Service](https://github.com/Azure/ARO-HCP/blob/main/cluster-service/cluster-creation.md)  
* In this document, we demonstrate how to achieve the same using `k8s` and [Azure Service Operator v2](https://azure.github.io/azure-service-operator/) with a declarative approach.

## Prerequisites

We expect the following:

* A `kind` cluster is being used (or any other Kubernetes cluster)  
* The following tools are installed:  
  * `az` CLI (or a `sp.json` file is already created)  
  * `kubectl` – these are prerequisites for creating the ARO-HCP infrastructure using the declarative approach  
  * `helm` – also required for setting up the infrastructure using the declarative approach

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
export AZURE_TENANT_ID=$(jq -r .tenant sp.json)
export AZURE_CLIENT_ID=$(jq -r .appId sp.json)
export AZURE_CLIENT_SECRET=$(jq -r .password sp.json)
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
cat <<EOF | kubectl apply -f -
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
## Crating infrastructure for ARO-HCP clusters
5. Then we can start such a deplouyment:
```bash
kubectl -f - <<EOF
# az group create --name <resource-group> --location <location>
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: mv-rg
  namespace: default
spec:
  location: eastus
---
# az network vnet create -n <vnet-name> -g <resource-group> --subnet-name <subnet-name>
apiVersion: network.azure.com/v1api20201101
kind: VirtualNetwork
metadata:
  name: mv-vnet
  namespace: default
spec:
  location: eastus
  owner:
    name: mv-rg
  addressSpace:
    addressPrefixes:
      - 10.100.0.0/15
---
# az network nsg create -n <nsg-name> -g <resource-group>
apiVersion: network.azure.com/v1api20201101
kind: NetworkSecurityGroup
metadata:
  name: mv-sg
  namespace: default
spec:
  location: eastus
  owner:
    name: mv-rg
---
# az network vnet create -n <vnet-name> -g <resource-group> --subnet-name <subnet-name>
# az network vnet subnet update -g <resource-group> -n <subnet-name> --vnet-name <vnet-name> --network-security-group <nsg-name>
apiVersion: network.azure.com/v1api20201101
kind: VirtualNetworksSubnet
metadata:
  name: mv-subnet
  namespace: default
spec:
  owner:
    name: mv-vnet
  addressPrefix: 10.100.76.0/24
  networkSecurityGroup: 
    reference:
      name: mv-sg
      group: network.azure.com
      kind: NetworkSecurityGroup
EOF
USER=mv
CS_CLUSTER_NAME=cluster1
OPERATORS_UAMIS_SUFFIX=$(openssl rand -hex 3)
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
kubectl apply -f - <<EOF
# az identity create -n ${IDENTITY_NAME} -g <resource-group>
apiVersion: managedidentity.azure.com/v1api20230131
kind: UserAssignedIdentity
metadata:
  name: ${IDENTITY_NAME}
  namespace: default
spec:
  location: eastus
  owner:
    name: mv-rg
EOF
done
```
6. Then we can check the result:
```bash
kubectl describe resourcegroup/mv-rg
```
The result should be:
```
Name:         mv-rg
Namespace:    default
Labels:       <none>
Annotations:  serviceoperator.azure.com/latest-reconciled-generation: 1
              serviceoperator.azure.com/operator-namespace: azureserviceoperator-system
              serviceoperator.azure.com/resource-id: /subscriptions/1d3378d3-5a3f-4712-85a1-2485495dfc4b/resourceGroups/mv-rg
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
  Azure Name:  mv-rg
  Location:    eastus
Status:
  Conditions:
    Last Transition Time:  2025-05-14T13:42:54Z
    Observed Generation:   1
    Reason:                Succeeded
    Status:                True
    Type:                  Ready
  Id:                      /subscriptions/1d3378d3-5a3f-4712-85a1-2485495dfc4b/resourceGroups/mv-rg
  Location:                eastus
  Name:                    mv-rg
  Properties:
    Provisioning State:  Succeeded
  Tags:
    Created At:  2025-05-14T13:42:52.1436530Z
  Type:          Microsoft.Resources/resourceGroups
Events:
  Type    Reason               Age                From                     Message
  ----    ------               ----               ----                     -------
  Normal  CredentialFrom       22s (x2 over 22s)  resources_resourcegroup  Using credential from "default/aso-credential"
  Normal  BeginCreateOrUpdate  19s                resources_resourcegroup  Successfully sent resource to Azure with ID "/subscriptions/1d3378d3-5a3f-4712-85a1-2485495dfc4b/resourceGroups/mv-rg"
```
