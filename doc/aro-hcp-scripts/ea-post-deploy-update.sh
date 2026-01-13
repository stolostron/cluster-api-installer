#!/bin/bash
export ARO_YAML_FILE="$1"
if [ -z "$ARO_YAML_FILE" ] ; then
   echo usage: $0 "<dir/aro.yaml>"
   exit 1
fi
if [ ! -f "$ARO_YAML_FILE" ] ; then
   echo "file: $ARO_YAML_FILE doesn't exists"
   exit 1
fi

if [ "$USE_KIND" = true ] ; then
    KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-aso2}
    KUBE_CONTEXT="--context=kind-$KIND_CLUSTER_NAME"
else
    OCP_CONTEXT=${OCP_CONTEXT:-crc-admin}
    KUBE_CONTEXT="--context=$OCP_CONTEXT"
fi

export CLUSTER_NAME=$(yq 'select(.kind == "AROControlPlane").spec.aroClusterName'     < "$ARO_YAML_FILE" )
export CLUSTER_NAMESPACE=$(yq 'select(.kind == "AROControlPlane").metadata.namespace' < "$ARO_YAML_FILE" )
export EA_AZURE_TENANT_ID=$(yq 'select(.kind == "AROControlPlane").spec.externalAuthProviders[0].issuer.issuerURL' < "$ARO_YAML_FILE"|sed -e 's;/v2.\0$;;' -e 's;.*/;;')
export EA_AZURE_CLIENT_ID=$(yq 'select(.kind == "AROControlPlane").spec.externalAuthProviders[0].issuer.audiences[0]' < "$ARO_YAML_FILE")
export GROUP_NAME="aro-hcp-engineering-App Developer"

export CONSOLE_URL=$(oc $KUBE_CONTEXT get -n "$CLUSTER_NAMESPACE" arocp "$CLUSTER_NAME-control-plane" -o json|jq -r '.status.consoleURL')

export CLUSTER_DOMAIN=${CONSOLE_URL##"https://console-openshift-console.apps."}

echo "K8s-Namespace: $CLUSTER_NAMESPACE"
echo " Cluster name: $CLUSTER_NAME"
echo "  Console URL: $CONSOLE_URL"
echo "       Domain: $CLUSTER_DOMAIN"
echo "EA: ClientID:  $EA_AZURE_CLIENT_ID"
echo "EA: TennantID: $EA_AZURE_TENANT_ID"
if [ -z "$CLUSTER_NAME" ] ; then
   echo no CLUSTER_NAME
   exit 1
fi
if [ -z "$CLUSTER_NAMESPACE" ] ; then
   echo no CLUSTER_NAMESPACE
   exit 1
fi
if [ -z "$CONSOLE_URL" -o "$CONSOLE_URL" = "null" ] ; then
   echo no CONSOLE_URL
   exit 1
fi
if [ -z "$EA_AZURE_CLIENT_ID" ] ; then
   echo no EA_AZURE_CLIENT_ID
   exit 1
fi
if [ -z "$EA_AZURE_TENANT_ID" ] ; then
   echo no EA_AZURE_TENANT_ID
   exit 1
fi

az ad app update --id "$EA_AZURE_CLIENT_ID" \
    --web-redirect-uris \
      "https://oauth-openshift.apps.$CLUSTER_DOMAIN/oauth2callback/AAD" \
      "$CONSOLE_URL/auth/callback"

az ad app update --id "$EA_AZURE_CLIENT_ID" \
    --enable-id-token-issuance true

az ad app update --id "$EA_AZURE_CLIENT_ID" \
    --optional-claims '{"idToken":[{"name":"groups","essential":false}]}'

# Enable security group claims in the token
az ad app update --id "$EA_AZURE_CLIENT_ID" --set groupMembershipClaims=SecurityGroup

# Add Microsoft Graph User.Read permission for group claims
# Microsoft Graph App ID: 00000003-0000-0000-c000-000000000000
# User.Read permission ID: e1fe6dd8-ba31-4d61-89e7-88639da4683d
az ad app permission add --id "$EA_AZURE_CLIENT_ID" \
    --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope 2>/dev/null || true

APP_SECRET_FILE="ea-secret-$EA_AZURE_CLIENT_ID.json"
if [ ! -f "$APP_SECRET_FILE" ] ; then
    az ad app credential reset --id $EA_AZURE_CLIENT_ID --append > "$APP_SECRET_FILE"
fi
export AZURE_CLIENT_SECRET=$(jq -r .password "$APP_SECRET_FILE")
if [ -z "$AZURE_CLIENT_SECRET" ] ; then
   echo no AZURE_CLIENT_SECRET in $APP_SECRET_FILE
   exit 1
fi

# Create the external auth console secret on the management cluster
# This secret is required for external auth synchronization
[ -n "$DELETE_SECRETS" ] && oc $KUBE_CONTEXT delete secret -n "$CLUSTER_NAMESPACE" "${CLUSTER_NAME}-ea-console-openshift-console"
oc $KUBE_CONTEXT create secret generic "${CLUSTER_NAME}-ea-console-openshift-console" \
    -n "$CLUSTER_NAMESPACE" \
    --from-literal=clientSecret="$AZURE_CLIENT_SECRET"

export KC="${CLUSTER_NAME}.kubeconfig"
oc $KUBE_CONTEXT get secret "${CLUSTER_NAME}-kubeconfig" -n "$CLUSTER_NAMESPACE" -o jsonpath='{.data.value}' | base64 -d > "$KC"

# WORKAROUND: Azure ARO HCP should create this secret automatically, but it doesn't
[ -n "$DELETE_SECRETS" ] && oc --kubeconfig="$KC" delete secret -n openshift-console "${CLUSTER_NAME}-ea-console-openshift-console"
oc --kubeconfig="$KC" create secret generic "${CLUSTER_NAME}-ea-console-openshift-console" \
    -n openshift-console \
    --from-literal=clientSecret="$AZURE_CLIENT_SECRET"

# Create the console-oauth-config secret required by the console operator
# This secret contains the OIDC client configuration
[ -n "$DELETE_SECRETS" ] && oc --kubeconfig="$KC" delete secret -n openshift-console console-oauth-config
oc --kubeconfig="$KC" create secret generic console-oauth-config \
    -n openshift-console \
    --from-literal=clientID="$EA_AZURE_CLIENT_ID" \
    --from-literal=clientSecret="$AZURE_CLIENT_SECRET" \
    --from-literal=issuer="https://login.microsoftonline.com/$EA_AZURE_TENANT_ID/v2.0" \
    --from-literal=extraScopes="openid,profile"

export USER_OBJECT_ID=$(az ad signed-in-user show --query id -o tsv)

oc --kubeconfig="$KC" create clusterrolebinding aad-admin \
    --clusterrole=cluster-admin \
    --user="${USER_OBJECT_ID}"

export GROUP_OBJECT_ID=$(az ad group show --group "$GROUP_NAME" --query id -o tsv)

oc --kubeconfig="$KC" create clusterrolebinding aad-admins-group \
    --clusterrole=cluster-admin \
    --group="${GROUP_OBJECT_ID}"

