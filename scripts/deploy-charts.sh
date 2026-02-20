#!/bin/bash
set -e
DO_INIT_KIND=${INIT_KIND:-true}
DO_DEPLOY=${DO_DEPLOY:-true}
DO_CHECK=${DO_CHECK:-true}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
declare -A DEPLOYMENTS=()

[ -s ./replace-params ] && . ./replace-params

if [ "$USE_KIND" = true -o "$USE_K8S" = true ] ; then
    [ "$USE_KIND" = true ] && CHART_SUFFIX="-kind"
    [ "$USE_K8S" = true ] && CHART_SUFFIX="-k8s"
    KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-aso2}
    KUBE_CONTEXT="--context=kind-$KIND_CLUSTER_NAME"
    echo "setting: KUBE_CONTEXT=$KUBE_CONTEXT"
    if [ "$DO_INIT_KIND" = true ] ; then
        echo "checking if the cluster exists: KIND_CLUSTER_NAME=$KIND_CLUSTER_NAME"
        ${SCRIPT_DIR}/setup-kind-cluster.sh
    fi
else
    OCP_CONTEXT=${OCP_CONTEXT:-crc-admin}
    KUBE_CONTEXT="--context=$OCP_CONTEXT"
    echo "setting: KUBE_CONTEXT=$KUBE_CONTEXT"
fi

function set_namespace_and_t {
    DEPLOYMENTS=()
    NAMESPACE=""
    if [ "$USE_K8S" = true ] ; then
        NAMESPACE="multicluster-engine"
    fi
    case "$PROJECT" in
      cluster-api)
        T="capi"
        NAMESPACE=${NAMESPACE:-"capi-system"}
        DEPLOYMENTS[$NAMESPACE]="${T}-controller-manager"
        if [ "$USE_KIND" != true -a "$USE_K8S" != true ] ; then
            DEPLOYMENTS[$NAMESPACE]="${DEPLOYMENTS[$NAMESPACE]} mce-capi-webhook-config"
        fi
        ;;
      cluster-api-provider-azure)
        T="capz"
        NAMESPACE=${NAMESPACE:-"capz-system"}
        DEPLOYMENTS[$NAMESPACE]="${T}-controller-manager azureserviceoperator-controller-manager"
        ;;
      cluster-api-provider-aws)
        T="capa"
        NAMESPACE=${NAMESPACE:-"capa-system"}
        DEPLOYMENTS[$NAMESPACE]="${T}-controller-manager"
        ;;
      cluster-api-provider-metal3)
        T="capm3"
        NAMESPACE=${NAMESPACE:-"capm3-system"}
        DEPLOYMENTS[$NAMESPACE]="mce-${T}-controller-manager"
        ;;
      cluster-api-provider-openshift-assisted)
        T="capoa"
        DEPLOYMENTS['capoa-bootstrap-system']="capoa-bootstrap-controller-manager"
        DEPLOYMENTS['capoa-controlplane-system']="capoa-controlplane-controller-manager"
        NAMESPACE=${NAMESPACE:-"capoa-controlplane-system capoa-bootstrap-system"}
        DEPLOYMENTS[$NAMESPACE]="capoa-bootstrap-controller-manager capoa-controlplane-controller-manager"
        ;;
    esac
}

CHARTS=$(echo cluster-api $*|tr ' ' '\n'|sort -u|tr '\n' ' ')

if [ "$DO_DEPLOY" = true ] ; then
    for PROJECT in $CHARTS ; do
        CHART="charts/$PROJECT$CHART_SUFFIX"
        [ -f $CHART/Chart.yaml ] || {
            echo "!!!!!!!!! SKIP DEPLOY: $CHART "
            continue
        }
        set_namespace_and_t
        echo ========= deploy: $CHART "using context: $KUBE_CONTEXT"
        echo "        PROJECT: $PROJECT"
        echo "      NAMESPACE: $NAMESPACE"
        if [ "$NAMESPACE" = "multicluster-engine" ] ; then
            kubectl $KUBE_CONTEXT get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl $KUBE_CONTEXT create namespace "$NAMESPACE" 
        fi
        echo "      HELM ARGS: --set Release.Namespace=$NAMESPACE" ${helm_add_args_a[$T]}
        helm template $CHART --include-crds --namespace "$NAMESPACE" --set "Release.Namespace=$NAMESPACE" ${helm_add_args_a[$T]}|kubectl $KUBE_CONTEXT apply -f - --server-side --force-conflicts
        echo
    done
fi


if [ "$DO_CHECK" = true ] ; then
    for PROJECT in $CHARTS ; do
        CHART="charts/$PROJECT$CHART_SUFFIX"
        [ -f $CHART/Chart.yaml ] || continue
        set_namespace_and_t
        for i in $NAMESPACE; do
            for D in ${DEPLOYMENTS[$i]} ; do
                echo "Waiting for $D controller (in $i namespace):"
                kubectl $KUBE_CONTEXT events -n "$i" --watch &
                CH_PID=$!
                trap "kill $CH_PID" EXIT
                kubectl $KUBE_CONTEXT -n "$i" wait deployment/${D} --for condition=Available=True  --timeout=10m
                kill $CH_PID
                echo
            done
        done
    done
fi


