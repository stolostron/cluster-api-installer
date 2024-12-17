#!/bin/bash
set -e
function subst_env_vars {
    local ORIG_FILE="$1"
    local T_FILE="$2"
    cp "$ORIG_FILE" "$T_FILE"
    declare -a subst=(
      "CAPI_DIAGNOSTICS_ADDRESS=:8443"
      "CAPI_INSECURE_DIAGNOSTICS=false"
      "CAPI_USE_DEPRECATED_INFRA_MACHINE_NAMING=false"
      "EXP_MACHINE_POOL=true"
      "EXP_CLUSTER_RESOURCE_SET=true"
      "CLUSTER_TOPOLOGY=false"
      "EXP_RUNTIME_SDK=false"
      "EXP_MACHINE_SET_PREFLIGHT_CHECKS=false"
    )
    for SUB in "${subst[@]}" ; do
       local WHAT="${SUB%=*}"
       local WITH="${SUB##*=}"
       sed -i "s;\${$WHAT[^}]*};$WITH;g" "$T_FILE" 
    done
}

PRJ=cluster-api
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

$KUSTOMIZE build config/$PRJ | $YQ ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > "$DST_PH"

echo "copy values file: src/$PRJ/values.yaml ->  $OUT_BASE/values.yaml"
cp "src/$PRJ/values.yaml" "$OUT_BASE/values.yaml"
sed -i -e 's/^\(    tag: vX.XX\).*/\1v'"$OCP_VERSION"/ "$OUT_BASE/values.yaml"
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
OUT_CRDS="$OUT_BASE/crds/"
mkdir -p "$OUT_CRDS"
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

for i in "$OUT_DIR"/* "$OUT_BASE/crds"/* ; do
    # sort all generated yaml files
    $YQ -i ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' "$i"
done

if [ "$SYNC2CHARTS" ] ;then
    echo syncing: $OUT_BASE/{values.yaml,templates} "-> charts/$PRJ"
    rm -rf charts/"$PRJ"/{templates,crds}
    cp -a $OUT_BASE/{values.yaml,templates,crds} charts/"$PRJ"
    # check the chart
    echo "apply templates: ./charts/$PRJ -> /tmp/$PRJ.yaml"
    helm template ./charts/"$PRJ" --include-crds |$YQ  ea '[.] | sort_by(.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' > /tmp/"$PRJ".yaml
    sed -i -e 's/^\(version|appVersion\): .*/\1: "'"$OCP_VERSION"'"/' ./charts/"$PRJ"/Chart.yaml
    rm ./charts/"$PRJ"/crds/ipa*.yaml
fi
