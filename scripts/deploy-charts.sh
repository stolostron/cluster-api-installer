#!/bin/bash
set -e
DO_INIT_KIND=${INIT_KIND:-true}
DO_DEPLOY=${DO_DEPLOY:-true}
DO_CHECK=${DO_CHECK:-true}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ -s ./replace-params ] && . ./replace-params

if [ "$USE_KIND" = true -o "$USE_K8S" = true ] ; then
    [ "$USE_KIND" = true ] && CHART_SUFFIX="-kind"
    [ "$USE_K8S" = true ] && CHART_SUFFIX="-k8s"
    KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-aso2}
    KUBE_CONTEXT="--context=kind-$KIND_CLUSTER_NAME"
    [ "$DO_INIT_KIND" = true ] && ${SCRIPT_DIR}/setup-kind-cluster.sh
else
    OCP_CONTEXT=${OCP_CONTEXT:-crc-admin}
    KUBE_CONTEXT="--context=$OCP_CONTEXT"
fi

function set_namespace_and_t {
    case "$PROJECT" in
      cluster-api)
        T="capi"
        NAMESPACE="capi-system"
        ;;
      cluster-api-provider-azure)
        T="capz"
        NAMESPACE="capz-system"
        ;;
      cluster-api-provider-aws)
        T="capa"
        NAMESPACE="capa-system"
        ;;
    esac
    if [ "$USE_K8S" = true ] ; then
        NAMESPACE="multicluster-engine"
    fi
}

CHARTS=$(echo cluster-api $*|tr ' ' '\n'|sort -u|tr '\n' ' ')

if [ "$DO_DEPLOY" = true ] ; then
    for PROJECT in $CHARTS ; do
        CHART="charts/$PROJECT$CHART_SUFFIX"
        [ -f $CHART/Chart.yaml ] || continue
        set_namespace_and_t
        echo ========= deploy: $CHART
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
        echo "Waiting for ${T} controller (in $NAMESPACE namespace):"
        kubectl $KUBE_CONTEXT events -n "$NAMESPACE" --watch &
        CH_PID=$!
        kubectl $KUBE_CONTEXT -n "$NAMESPACE" wait deployment/${T}-controller-manager --for condition=Available=True  --timeout=10m
        if [ "${T}" = capz ] ; then
            echo "Waiting for azureserviceoperator controller (in $NAMESPACE namespace):"
            kubectl $KUBE_CONTEXT -n "$NAMESPACE" wait deployment/azureserviceoperator-controller-manager --for condition=Available=True  --timeout=10m
        fi
        if [ "${T}" = capi ] ; then
            if [ "$USE_KIND" != true -a "$USE_K8S" != true ] ; then
                echo "Waiting for mce-capi-webhook-config controller (in $NAMESPACE namespace):"
                kubectl $KUBE_CONTEXT -n "$NAMESPACE" wait deployment/mce-capi-webhook-config --for condition=Available=True  --timeout=10m
            fi
        fi
        kill $CH_PID
        echo
    done
fi


