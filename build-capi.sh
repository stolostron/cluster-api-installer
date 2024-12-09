#!/bin/bash
set -e
function subst_env_vars {
    local ORIG_FILE="$1"
    local T_FILE="$2"
    cp "$ORIG_FILE" "$T_FILE"
    declare -a subst=(
      "CAPI_DIAGNOSTICS_ADDRESS=:__.Values.manager.diagnosticsAddress__"
      "CAPI_INSECURE_DIAGNOSTICS=__.Values.manager.insecureDiagnostics__"
      "CAPI_USE_DEPRECATED_INFRA_MACHINE_NAMING=__.Values.manager.useDeprecatedInfraMachineNaming__"
      "EXP_MACHINE_POOL=__.Values.manager.featureGates.machinePool__"
      "EXP_CLUSTER_RESOURCE_SET=__.Values.manager.featureGates.clusterResourceSet__"
      "CLUSTER_TOPOLOGY=__.Values.manager.featureGates.clusterTopology__"
      "EXP_RUNTIME_SDK=__.Values.manager.featureGates.runtimeSDK__"
      "EXP_MACHINE_SET_PREFLIGHT_CHECKS=__.Values.manager.featureGates.machineSetPreflightChecks__"
    )
    for SUB in "${subst[@]}" ; do
       local WHAT="${SUB%=*}"
       local WITH="${SUB##*=}"
       sed -i "s;\${$WHAT[^}]*};$WITH;g" "$T_FILE" 
    done
    sed -i -e 's/\({{\|}}\)/{{ "\1" }}/g' "$T_FILE"
}
function subst_placeholders {
    local T_FILE="$1"
    sed -i 's;__\(.Values.[^_]\+\)__;{{ \1 }};g' "$T_FILE"
    TMP_F=$(mktemp)
    while true ; do
        F_LINE=$(grep '[[:space:]]*\(- \|\)'"'"'*zzz_.READ_FILE._:' "$T_FILE"|head -1)
        [ -z "$F_LINE" ] && break
        INDENT="${F_LINE%%zzz_*}"
        INDENT="${INDENT%%\'}"
        INDENT="${INDENT%%\ \ -\ }"
        R_FILE="${F_LINE#*zzz_.READ_FILE._:\ }"
        R_FILE="${R_FILE%\'}"
        R_FILE="src/$PRJ/placeholders/add/$R_FILE"
        sed -e "s;^;$INDENT;" "$R_FILE" > $TMP_F
        sed -i -e "/^${F_LINE}$/r $TMP_F" -e "//d" "$T_FILE"
    done
    rm -f "$TMP_F"
}
function remove_cert_manager {
    local T_FILE="$1"
    if [ "${USE_OC_CERT=yes}" == "yes" ] ; then
        yq -i 'select(.metadata.annotations."cert-manager.io/inject-ca-from"=="capi-system/capi-serving-cert").metadata.annotations."service.beta.openshift.io/inject-cabundle"="true"' "$T_FILE"
        yq -i 'del(.metadata.annotations."cert-manager.io/inject-ca-from")' "$T_FILE"
        echo "using: USE_OC_CERT=yes"
    fi
}

PRJ=cluster-api
#SRC="../cluster-api"
SRC="../cluster-api-ocp"
if [ -f "$SRC/openshift/core-components.yaml" ] ; then
    VERSION="ocp-4.18"
    SRC_CC="$SRC/openshift/core-components.yaml"
else
    (cd "$SRC"; make release-manifests)
    VERSION=$(yq '.info.version' "$SRC"/out/runtime-sdk-openapi.yaml)
    SRC_CC="$SRC/cluster-api/out/core-components.yaml"
fi

echo "-------------------------"
echo "PRJ=$PRJ VERSION=$VERSION"
OUT_BASE="out/$PRJ/${VERSION=_unknown_}"
OUT_DIR="$OUT_BASE/templates"
SRC_PH="config/$PRJ/base/core-components.yaml"
DST_PH="config/$PRJ/out/core-components.yaml"
mkdir -p "config/$PRJ/pre" "config/$PRJ/base"
echo "creating placeholders file: $SRC_CC ->  $SRC_PH"
rm -f "config/$PRJ/base"/core-components*.yaml
subst_env_vars "$SRC_CC" "$SRC_PH"
remove_cert_manager "$SRC_PH"
/home/mveber/projekty/capi/cluster-api/hack/tools/bin/kustomize build config/$PRJ | yq ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > "$DST_PH"

echo "copy values file: src/$PRJ/values.yaml ->  $OUT_BASE/values.yaml"
cp "src/$PRJ/values.yaml" "$OUT_BASE/values.yaml"
rm -rf "$OUT_BASE/templates"; mkdir -p "$OUT_BASE/templates"

# The helm chart must contain the 
# 0. namespace
OUT_NAMESPACE="$OUT_DIR/namespace.yaml"
yq 'select(.kind == "Namespace")'  "$DST_PH"   > "$OUT_NAMESPACE"
echo "generated: $OUT_NAMESPACE"

# 1. deployment
OUT_DEPLOY="$OUT_DIR/deployment.yaml"
yq 'select(.kind == "Deployment")'  "$DST_PH"   > "$OUT_DEPLOY"
echo "generated: $OUT_DEPLOY"

# 2. CRDs (each crd in different file)
OUT_CRDS="$OUT_DIR/crd-"
yq 'select(.kind == "CustomResourceDefinition")'  "$DST_PH"| yq --split-exp "\"$OUT_CRDS\""' + .metadata.name + ".yaml"'
echo "generated: $OUT_CRDS*"

# 3. service
OUT_SERVICE="$OUT_DIR/service.yaml"
yq 'select(.kind == "Service")'  "$DST_PH"  > "$OUT_SERVICE"
echo "generated: $OUT_SERVICE"

# 4. webhookValidation
OUT_WEBHOOKS="$OUT_DIR/webhookValidation.yaml"
yq 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")'  "$DST_PH"   > "$OUT_WEBHOOKS"
echo "generated: $OUT_WEBHOOKS"

# 5. required Roles.
OUT_ROLES="$OUT_DIR/roles.yaml"
yq 'select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding")'  "$DST_PH" > "$OUT_ROLES"
echo "generated: $OUT_ROLES"

for i in "$OUT_DIR"/* ; do
    yq -i ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' "$i"
    subst_placeholders "$i"
done

if [ "$SYNC2CHARTS" ] ;then
    echo syncing: $OUT_BASE/{values.yaml,templates} "-> charts/cluster-api"
    rm -rf charts/cluster-api/templates
    cp -a $OUT_BASE/{values.yaml,templates} charts/cluster-api
    # check the chart
    helm template ./charts/cluster-api |yq  ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > /tmp/x.yaml
fi

## unused: Issuer, Certificate, Namespace
## added: ClusterRoleBinding/capi-admin-rolebinding
