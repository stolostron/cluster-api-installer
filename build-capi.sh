#!/bin/bash
set -e
function add_placeholders {
    local ORIG_FILE="$1"
    local T_FILE="$2"
    cp "$ORIG_FILE" "$T_FILE"

    local PRJ="${T_FILE##out/}"
    PRJ="${PRJ%%/*}"

    CMD_FILE="src/$PRJ/placeholders.cmd"
    cat "$CMD_FILE"|while read CMD ; do
       local T="${CMD%%:*}"
       CMD="${CMD#*:}"
       local WHAT="${CMD%=*}"
       local WITH="${CMD##*=}"
       if [ "$T" == "ENV" ] ; then
           sed -i "s;\${$WHAT[^}]*};$WITH;g" "$T_FILE" 
           continue
       fi
       if [ "$T" == "SET" ] ; then
           WITH=$(echo "$WITH"|sed -e 's;\(.Values\.[.a-zA-Z_]\+\);__\1__;g')
           yq -i "$WHAT=\"${WITH}\"" "$T_FILE" 
           continue
       fi
       if [ "$T" == "ADD" ] ; then
           yq -i "$WHAT.\"zzz_.READ_FILE._\"=\"${WITH}\"" "$T_FILE" 
           continue
       fi
       if [ "$T" == "REP" ] ; then
           yq -i "$WHAT=\"zzz_.READ_FILE._: ${WITH}\"" "$T_FILE" 
           continue
       fi
    done
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
PLACEHOLDERS_DIR="$OUT_BASE/placeholders"
mkdir -p "$OUT_DIR" "$PLACEHOLDERS_DIR"
SRC_PH="$PLACEHOLDERS_DIR/core-components.yaml"
echo "creating placeholders file: $SRC_CC ->  $SRC_PH"
add_placeholders "$SRC_CC" "$SRC_PH"
echo "copy values file: src/$PRJ/values.yaml ->  $OUT_BASE/values.yaml"
cp "src/$PRJ/values.yaml" "$OUT_BASE/values.yaml"

# The helm chart must contain the 
# 1. deployment
OUT_DEPLOY="$OUT_DIR/deployment.yaml"
#charts/cluster-api/templates/capi-out.yaml
yq 'select(.kind == "Deployment")'  "$SRC_PH" | yq ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)'  > "$OUT_DEPLOY"
# yq -i '.metadata.namespace="__.Values.namespace__", .spec.replicas="__.Values.replicaCount__", '\
#     "$OUT_DEPLOY"
echo "generated: $OUT_DEPLOY"

# 2. CRDs (each crd in different file)
OUT_CRDS="$OUT_DIR/capi-crd.yaml"
yq 'select(.kind == "CustomResourceDefinition")'  "$SRC_PH" > "$OUT_CRDS"
if [ "${USE_OC_CERT=yes}" == "yes" ] ; then
    yq -i 'select(.metadata.annotations."cert-manager.io/inject-ca-from"=="capi-system/capi-serving-cert").metadata.annotations."service.beta.openshift.io/inject-cabundle"="true"' "$OUT_CRDS"
    yq -i 'del(.metadata.annotations."cert-manager.io/inject-ca-from")' "$OUT_CRDS"
    sed -i -e 's/\({{\|}}\)/{{ "\1" }}/g' "$OUT_CRDS"
    echo "using: USE_OC_CERT=yes"
fi
echo "generated: $OUT_CRDS"

# 3. service
OUT_SERVICE="$OUT_DIR/service.yaml"
yq 'select(.kind == "Service")'  "$SRC_PH"  > "$OUT_SERVICE"
echo "generated: $OUT_SERVICE"

# 4. webhookValidation
OUT_WEBHOOKS="$OUT_DIR/webhookValidation.yaml"
yq 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration")'  "$SRC_PH" src/cluster-api/capi-admin-rolebinding.yaml   > "$OUT_WEBHOOKS"
if [ "${USE_OC_CERT=yes}" == "yes" ] ; then
    yq -i 'select(.metadata.annotations."cert-manager.io/inject-ca-from"=="capi-system/capi-serving-cert").metadata.annotations."service.beta.openshift.io/inject-cabundle"="true"' "$OUT_WEBHOOKS"
    yq -i 'del(.metadata.annotations."cert-manager.io/inject-ca-from")' "$OUT_WEBHOOKS"
    echo "using: USE_OC_CERT=yes"
fi
echo "generated: $OUT_WEBHOOKS"

# 5. required Roles.
OUT_ROLES="$OUT_DIR/roles.yaml"
yq 'select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding")'  "$SRC_PH" src/cluster-api/capi-admin-rolebinding.yaml  > "$OUT_ROLES"
echo "generated: $OUT_ROLES"

for i in "$OUT_DIR"/* ; do
    yq -i ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' "$i"
    subst_placeholders "$i"
done

if [ "$SYNC2CHARTS" ] ;then
    rm -rf charts/cluster-api/templates
    cp -a $OUT_BASE/{values.yaml,templates} charts/cluster-api
    # check the chart
    helm template ./charts/cluster-api |yq  ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > /tmp/x.yaml
fi

## unused: Issuer, Certificate, Namespace
## added: ClusterRoleBinding/capi-admin-rolebinding
