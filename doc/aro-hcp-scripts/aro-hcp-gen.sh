#!/bin/bash
TEMPLATE_FILE=aro-hcp-scripts/aro-template.yaml

# az cli
export AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)

# infra-names.js (created by aro-prepare-infra.sh)
export CS_CLUSTER_NAME=$(jq   -r .CS_CLUSTER_NAME   infra-names.js)
export RESOURCEGROUPNAME=$(jq -r .RESOURCEGROUPNAME infra-names.js)
export VNET=$(jq              -r .VNET              infra-names.js)
export SUBNET=$(jq            -r .SUBNET            infra-names.js)
export REGION=$(jq            -r .REGION            infra-names.js)
export USER=$(jq              -r .USER              infra-names.js)
export NSG=$(jq               -r .NSG               infra-names.js)
export OPERATORS_UAMIS_SUFFIX=$(jq -r .OPERATORS_UAMIS_SUFFIX infra-names.js)


export AZURE_TENANT_ID=$(jq          -r .tenant   sp.json)
export AZURE_CLIENT_ID=$(jq          -r .appId    sp.json)
export AZURE_CLIENT_SECRET=$(jq      -r .password sp.json)
# Settings needed for AzureClusterIdentity used by the AzureCluster
export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
export CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="default"
oc create secret generic "${AZURE_CLUSTER_IDENTITY_SECRET_NAME}" --from-literal=clientSecret="${AZURE_CLIENT_SECRET}" --namespace "${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}"
cat <<EOF | kubectl apply -f -
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: AzureClusterIdentity                                                                                                                                                                                                                   
metadata:
  name: ${CLUSTER_IDENTITY_NAME}
  namespace: ${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}
spec:
  allowedNamespaces:
    list: [] # minItems 0 of type string
  clientSecret:
    name: ${AZURE_CLUSTER_IDENTITY_SECRET_NAME}
    namespace: ${AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE}
  tenantID: ${AZURE_TENANT_ID}
  type: "ServicePrincipal" # "ServicePrincipal", "UserAssignedMSI", "ManualServicePrincipal", "ServicePrincipalCertificate", "WorkloadIdentity", "UserAssignedIdentityCredential"
---
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


# missing in aro-cluste: MANAGEDRGNAME="$USER-$CS_CLUSTER_NAME-managed-rg"
envsubst  < $TEMPLATE_FILE
