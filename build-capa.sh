#!/bin/bash
set -e
function subst_env_vars {
    local ORIG_FILE="$1"
    local T_FILE="$2"
    cp "$ORIG_FILE" "$T_FILE"
    declare -a subst=(
      "AWS_B64ENCODED_CREDENTIALS=__.Values.aws.encodedCredentials__"
      "AWS_CONTROLLER_IAM_ROLE/="
      "AWS_CONTROLLER_IAM_ROLE=__.Values.aws.iamRole__"
      "K8S_CP_LABEL:=node-role.kubernetes.io/control-plane"
      "CAPA_DIAGNOSTICS_ADDRESS=:8443"
      "CAPA_INSECURE_DIAGNOSTICS=false"
      "CAPA_LOGLEVEL=0"
      "EXP_MACHINE_POOL=true"
      "CAPA_EKS=true"
      "CAPA_EKS_IAM=false"
      "CAPA_EKS_ADD_ROLES=false"
      "EXP_EKS_FARGATE=false"
      "EVENT_BRIDGE_INSTANCE_STATE=false"
      "AUTO_CONTROLLER_IDENTITY_CREATOR=false"
      "EXP_BOOTSTRAP_FORMAT_IGNITION=false"
      "EXP_EXTERNAL_RESOURCE_GC=false"
      "EXP_ALTERNATIVE_GC_STRATEGY=false"
      "TAG_UNMANAGED_NETWORK_RESOURCES=false"
      "EXP_ROSA=true"
    )
    for SUB in "${subst[@]}" ; do
       local WHAT="${SUB%=*}"
       local WITH="${SUB##*=}"
       sed -i "s;\${$WHAT[^}]*};$WITH;g" "$T_FILE" 
    done
}
function subst_placeholders {
    local T_FILE="$1"
    sed -i -e 's/\({{\|}}\)/{{ "\1" }}/g' "$T_FILE"
    sed -i -e 's;__\(.Values.[^_]\+\)__;{{ \1 }};g' "$T_FILE"
    TMP_F=$(mktemp)
    while true ; do
        F_LINE=$(grep '[[:space:]]*\(- \|\)'"'"'*z.._.READ_FILE._:' "$T_FILE"|head -1)
        [ -z "$F_LINE" ] && break
        INDENT="${F_LINE%%z??_*}"
        INDENT="${INDENT%%\'}"
        INDENT="${INDENT%%\ \ -\ }"
        R_FILE="${F_LINE#*z??_.READ_FILE._:\ }"
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
        $YQ -i 'select(.metadata.annotations."cert-manager.io/inject-ca-from"=="capa-system/capa-serving-cert").metadata.annotations."service.beta.openshift.io/inject-cabundle"="true"' "$T_FILE"
        $YQ -i 'del(.metadata.annotations."cert-manager.io/inject-ca-from")' "$T_FILE"
        echo "using: USE_OC_CERT=yes"
    fi
    $YQ -i '' "$T_FILE"
}

PRJ=cluster-api-provider-aws
[ -z "$OCP_VERSION" ] && OCP_VERSION="4.18"
BRANCH="release-$OCP_VERSION"
mkdir -p openshift

if [ -z "$YQ" ] ; then
    echo "# using yq: $PWD/hack/tools/yq"
    YQ="$PWD/hack/tools/yq"
fi
if [ ! -x "$YQ" ] ; then
    echo "executable yq not found: $YQ"
    echo "use: make helm-capi"
    exit -1
fi
if [ -z "$KUSTOMIZE" ] ; then
    echo "# using kustomize: $PWD/hack/tools/kustomize"
    KUSTOMIZE="$PWD/hack/tools/kustomize"
fi
if [ ! -x "$KUSTOMIZE" ] ; then
    echo "executable kustomize not found: $KUSTOMIZE"
    echo "use: make helm-capi"
    exit -1
fi

SRC="openshift/$PRJ"
if [ ! -d "$SRC" ] ; then
    git clone https://github.com/openshift/"$PRJ" "$SRC"
fi
SRC_CC="$PWD/openshift/$PRJ-components.yaml"
(cd $SRC; git checkout "$BRANCH"; git pull)
(cd $SRC; $KUSTOMIZE build config/default) > "$SRC_CC"

echo "-------------------------"
echo "PRJ=$PRJ BRANCH=$BRANCH"
OUT_BASE="out/$PRJ/${BRANCH=_unknown_}"
OUT_DIR="$OUT_BASE/templates"
SRC_PH="config/$PRJ/base/core-components.yaml"
DST_PH="config/$PRJ/out/core-components.yaml"
rm -rf "$OUT_BASE"
mkdir -p "config/$PRJ"/{out,base} "$OUT_BASE"
echo "creating placeholders file: $SRC_CC ->  $SRC_PH"
rm -f "config/$PRJ/base"/core-components*.yaml
subst_env_vars "$SRC_CC" "$SRC_PH"
remove_cert_manager "$SRC_PH"

$KUSTOMIZE build config/$PRJ | $YQ ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > "$DST_PH"

echo "copy values file: src/$PRJ/values.yaml ->  $OUT_BASE/values.yaml"
cp "src/$PRJ/values.yaml" "$OUT_BASE/values.yaml"
sed -i -e 's/^\(    tag: \).*/\1v'"$OCP_VERSION"/ "$OUT_BASE/values.yaml"
rm -rf "$OUT_BASE/templates"; mkdir -p "$OUT_BASE/templates"

# The helm chart must contain the 
# 0. namespace
OUT_NAMESPACE="$OUT_DIR/namespace.yaml"
$YQ 'select(.kind == "Namespace")'  "$DST_PH"   > "$OUT_NAMESPACE"
echo "generated: $OUT_NAMESPACE"

# 1. deployment
OUT_DEPLOY="$OUT_DIR/deployment.yaml"
$YQ 'select(.kind == "Deployment")'  "$DST_PH"   > "$OUT_DEPLOY"
echo "generated: $OUT_DEPLOY"

# 2. CRDs (each crd in different file)
OUT_CRDS="$OUT_DIR/crd-"
$YQ 'select(.kind == "CustomResourceDefinition")'  "$DST_PH"| $YQ --split-exp "\"$OUT_CRDS\""' + .metadata.name + ".yaml"'
echo "generated: $OUT_CRDS*"

# 3. service
OUT_SERVICE="$OUT_DIR/service.yaml"
$YQ 'select(.kind == "Service")'  "$DST_PH"  > "$OUT_SERVICE"
echo "generated: $OUT_SERVICE"

# 4. webhookValidation
OUT_WEBHOOKS="$OUT_DIR/webhookValidation.yaml"
$YQ 'select(.kind == "ValidatingWebhookConfiguration" or .kind == "MutatingWebhookConfiguration" or .kind == "ValidatingAdmissionPolicyBinding" or .kind == "ValidatingAdmissionPolicy")'  "$DST_PH"   > "$OUT_WEBHOOKS"
echo "generated: $OUT_WEBHOOKS"

# 5. required Roles.
OUT_ROLES="$OUT_DIR/roles.yaml"
$YQ 'select(.kind == "ServiceAccount" or .kind == "Role" or .kind == "RoleBinding" or .kind == "ClusterRole" or .kind == "ClusterRoleBinding" or .kind == "Secret")'  "$DST_PH" > "$OUT_ROLES"
echo "generated: $OUT_ROLES"

for i in "$OUT_DIR"/* ; do
    $YQ -i ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' "$i"
    subst_placeholders "$i"
done

if [ "$SYNC2CHARTS" ] ;then
    echo syncing: $OUT_BASE/{values.yaml,templates} "-> charts/$PRJ"
    rm -rf charts/"$PRJ"/templates
    cp -a $OUT_BASE/{values.yaml,templates} charts/"$PRJ"
    # check the chart
    echo "apply templates: ./charts/$PRJ -> /tmp/$PRJ.yaml"
    helm template ./charts/"$PRJ" |$YQ  ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > /tmp/"$PRJ".yaml
    sed -i -e 's/^\(version|appVersion\): .*/\1: "'"$OCP_VERSION"'"/' ./charts/"$PRJ"/Chart.yaml
fi

## unused: Issuer, Certificate, Namespace
## added: ClusterRoleBinding/capi-admin-rolebinding
