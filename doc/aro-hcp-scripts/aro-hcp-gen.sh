#!/bin/bash
if [ -n "$1" ] ; then
    GEN_OUTPUT="$1"; shift
else
    echo "usage: $0 <output-dir>"
    exit 1
fi
set -e
export ENV=${ENV:-stage}
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-aso2}"
export CREATE_CREDENTIALS=true

if [ "$KIND_CLUSTER_NAME" == "capz-mveber-int" ] ; then
    export OICD_RESOURCE_GROUP=mveber-oidc-issuer
    export USER_ASSIGNED_IDENTITY_ASO=mveber-aso-tests
    export USER_ASSIGNED_IDENTITY_ARO=mveber-aro-tests
    export ENV=int
fi
export NAMESPACE=${NAMESPACE:-default}


if [ "$ENV" == int ] ; then
    export AZURE_SUBSCRIPTION_NAME=${AZURE_SUBSCRIPTION_NAME:-"ARO SRE Team - INT (EA Subscription 3)"}
    export REGION=${REGION:-uksouth}
fi

if [ "$ENV" == stage ] ; then
    export AZURE_SUBSCRIPTION_NAME=${AZURE_SUBSCRIPTION_NAME:-"ARO HCP - STAGE testing (EA Subscription)"}
    export REGION=${REGION:-uksouth}
fi

export AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv     --subscription "$AZURE_SUBSCRIPTION_NAME")
if [ -z "$AZURE_SUBSCRIPTION_ID" ]; then
    echo "No such subscription: AZURE_SUBSCRIPTION_NAME=$AZURE_SUBSCRIPTION_NAME"
    exit 1
fi
export AZURE_SUBSCRIPTION_NAME=$(az account show --query name --output tsv --subscription "$AZURE_SUBSCRIPTION_NAME")

echo "AZURE_SUBSCRIPTION_NAME=$AZURE_SUBSCRIPTION_NAME <$AZURE_SUBSCRIPTION_ID>"

export USER=${USER:-user1}
export CS_CLUSTER_NAME=${CS_CLUSTER_NAME:-$USER-$ENV}
export NAME_PREFIX=${NAME_PREFIX:-$CS_CLUSTER_NAME}
export RESOURCEGROUPNAME="$CS_CLUSTER_NAME-resgroup"
export OCP_VERSION=${OCP_VERSION:-4.20}
export OCP_VERSION_MP=${OCP_VERSION_MP:-$OCP_VERSION.0}
export REGION=${REGION:-westus3}
export NODEPOOL_PREFIX="w-${REGION:0:7}"

if [ -n "$OICD_RESOURCE_GROUP" ] ; then
    export AZURE_ASO_TENANT_ID=$(az identity show --query tenantId --output=tsv --resource-group="${OICD_RESOURCE_GROUP}" --name="${USER_ASSIGNED_IDENTITY_ASO}" --subscription "$AZURE_SUBSCRIPTION_NAME")
    export AZURE_ASO_CLIENT_ID=$(az identity show --query clientId --output=tsv --resource-group="${OICD_RESOURCE_GROUP}" --name="${USER_ASSIGNED_IDENTITY_ASO}" --subscription "$AZURE_SUBSCRIPTION_NAME")
    export AZURE_ASO_PRINCIPAL_ID=$(az identity show --query principalId --output=tsv --resource-group="${OICD_RESOURCE_GROUP}" --name="${USER_ASSIGNED_IDENTITY_ASO}" --subscription "$AZURE_SUBSCRIPTION_NAME")
    # az role assignment create --assignee  "${AZURE_ASO_PRINCIPAL_ID}" --role Contributor --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}"
    export AZURE_TENANT_ID=$(az identity show --query tenantId --output=tsv --resource-group="${OICD_RESOURCE_GROUP}" --name="${USER_ASSIGNED_IDENTITY_ARO}" --subscription "$AZURE_SUBSCRIPTION_NAME")
    export AZURE_CLIENT_ID=$(az identity show --query clientId --output=tsv --resource-group="${OICD_RESOURCE_GROUP}" --name="${USER_ASSIGNED_IDENTITY_ARO}" --subscription "$AZURE_SUBSCRIPTION_NAME")
    export AZURE_PRINCIPAL_ID=$(az identity show --query principalId --output=tsv --resource-group="${OICD_RESOURCE_GROUP}" --name="${USER_ASSIGNED_IDENTITY_ARO}" --subscription "$AZURE_SUBSCRIPTION_NAME")
    # az role assignment create --assignee  "${AZURE_PRINCIPAL_ID}" --role Contributor --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}"
else
    SP_JSON_FILE="sp-$AZURE_SUBSCRIPTION_ID.json"
    if [ ! -s "$SP_JSON_FILE" ] ; then
        let "randomIdentifier=$RANDOM*$RANDOM"
        servicePrincipalName="$USER-sp-$randomIdentifier"
        #roleName="Contributor"
        roleName="Custom-Owner (Block Billing and Subscription deletion)"
        echo "Creating SP for RBAC with name $servicePrincipalName, with role $roleName and in scopes /subscriptions/$AZURE_SUBSCRIPTION_ID"
        az ad sp create-for-rbac --name "$servicePrincipalName" --role "$roleName" --scopes "/subscriptions/$AZURE_SUBSCRIPTION_ID" > "$SP_JSON_FILE"
    fi
    if [ -n "${ASSIGN_ROLE_SP}" ] ; then
        roleName="Custom-Owner (Block Billing and Subscription deletion)"
        export ASSIGN_ROLE_SP_NAME=$(jq -r .displayName "$SP_JSON_FILE")
        ASSIGN_ROLE_SP_ID=$(az ad sp list --output=json  --display-name mveber-sp-468528336 |jq -r '.[0].id')
        echo "assign ASSIGN_ROLE_SP_NAME=$ASSIGN_ROLE_SP_NAME to scope /subscriptions/$AZURE_SUBSCRIPTION_ID"
        az role assignment create --assignee  "${ASSIGN_ROLE_SP_ID}" --role "$roleName" --scope "/subscriptions/${AZURE_SUBSCRIPTION_ID}"
    fi
    export AZURE_TENANT_ID=$(jq -r .tenant "$SP_JSON_FILE")
    export AZURE_CLIENT_ID=$(jq -r .appId "$SP_JSON_FILE")
    export AZURE_CLIENT_SECRET=$(jq -r .password "$SP_JSON_FILE")
fi

OPERATORS_UAMIS_SUFFIX_FILE=operators-uamis-suffix.txt
if [ ! -f "$OPERATORS_UAMIS_SUFFIX_FILE" ] ; then
    openssl rand -hex 3 > "$OPERATORS_UAMIS_SUFFIX_FILE"
fi
export OPERATORS_UAMIS_SUFFIX=$(cat "$OPERATORS_UAMIS_SUFFIX_FILE")

export VNET="$NAME_PREFIX-vnet"
export SUBNET="$NAME_PREFIX-subnet"
export NSG="$NAME_PREFIX-nsg"
export KV="$NAME_PREFIX-kv"
export KV_VERSION="40037529f72042cbb4f69ddb97b8bced"

# Settings needed for AzureClusterIdentity used by the AzureCluster
export AZURE_CLUSTER_IDENTITY_NAME="cluster-identity"
export AZURE_CLUSTER_IDENTITY_NAMESPACE="$NAMESPACE"
if [ -n "${AZURE_CLIENT_SECRET}" ] ; then
    export AZURE_CLUSTER_IDENTITY_SECRET_NAME="cluster-identity-secret"
    export AZURE_CLUSTER_IDENTITY_SECRET_NAMESPACE="$NAMESPACE"
    export AZURE_CLUSTER_IDENTITY_SECRET_BASE64=$(echo -n "$AZURE_CLIENT_SECRET"|base64)
fi

export USE_EA=${USE_EA:-true}
export EA_OIDC_USERNAME_CLAIM=${OIDC_USERNAME_CLAIM:-oid}
export EA_OIDC_GROUPS_CLAIM=${OIDC_GROUPS_CLAIM:-groups}
export EA_OIDC_PROVIDER_NAME=${CS_CLUSTER_NAME}-ea
export EA_AZURE_TENANT_ID=${AZURE_TENANT_ID}
export EA_AZURE_CLIENT_ID=${AZURE_CLIENT_ID}
export EA_DISABLE='#'
[ "$USE_EA" = true ] && EA_DISABLE=''

echo ENV=$ENV - AZURE_SUBSCRIPTION_NAME=${AZURE_SUBSCRIPTION_NAME} AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}
echo AZURE_TENANT_ID=${AZURE_TENANT_ID}
echo AZURE_CLIENT_ID=${AZURE_CLIENT_ID} AZURE_ASO_CLIENT_ID=${AZURE_ASO_CLIENT_ID} 
mkdir -p "$GEN_OUTPUT"
if [ -n "$CREATE_CREDENTIALS" ] ; then
    if [ -n "${OICD_RESOURCE_GROUP}" ] ; then
        # credentials using WorkloadIdentity
        TEMPLATE_FILE_CRE=$(dirname $0)/credentials-wi-template.yaml
    else
        # credentials using ServicePrincipal
        TEMPLATE_FILE_CRE=$(dirname $0)/credentials-sp-template.yaml
    fi
    echo creating: "$GEN_OUTPUT/credentials.yaml"
    envsubst  < $TEMPLATE_FILE_CRE > "$GEN_OUTPUT/credentials.yaml"
fi

TEMPLATE_FILE_ARO=$(dirname $0)/aro-template.yaml
TEMPLATE_FILE_IS=$(dirname $0)/is-template.yaml


if [ -z "$GEN_ASO" ] ; then
    echo creating: "$GEN_OUTPUT/aro.yaml"
    envsubst  < $TEMPLATE_FILE_ARO > "$GEN_OUTPUT/aro.yaml"
else
    echo creating: "$GEN_OUTPUT/is.yaml"
    envsubst  < $TEMPLATE_FILE_IS > "$GEN_OUTPUT/is.yaml"

    TEMPLATE_FILE_ASO=$(dirname $0)/aro-aso-template.yaml
    TEMPLATE_FILE_ASO_EA=$(dirname $0)/aro-aso-ea-template.yaml
    echo creating: "$GEN_OUTPUT/aro-aso.yaml"
    envsubst  < $TEMPLATE_FILE_ASO > "$GEN_OUTPUT/aro-aso.yaml"
    if [ "$USE_EA" == true ] ; then
        echo creating: "$GEN_OUTPUT/aro-ea.yaml"
        envsubst  < $TEMPLATE_FILE_ASO_EA > "$GEN_OUTPUT/aro-ea.yaml"
    fi
fi
