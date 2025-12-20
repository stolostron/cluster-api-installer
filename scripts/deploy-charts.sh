#!/bin/bash
set -e

if [ "$USE_KIND" = true ] ; then
    CHART_SUFFIX="-k8s"
    KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-aso2}
    KUBE_CONTEXT="--context=kind-$KIND_CLUSTER_NAME"
    
    if ! (kind get clusters 2>/dev/null|grep -q '^'"$KIND_CLUSTER_NAME"'$') ; then 
        kind create cluster --name "$KIND_CLUSTER_NAME" --image="kindest/node:v1.31.0"
        helm repo add jetstack https://charts.jetstack.io --force-update
        helm repo update
        helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout 5m
    fi
else
    OCP_CONTEXT=${OCP_CONTEXT:-crc-admin}
    KUBE_CONTEXT="--context=$OCP_CONTEXT"
fi

function set_namespace_and_t {
    case "$PROJECT" in
      cluster-api)
        T="capi"
        if [ -z "$CHART_SUFFIX" ] ; then
           NAMESPACE="capi-system"
        else
           kubectl $KUBE_CONTEXT create namespace multicluster-engine || true
           NAMESPACE="multicluster-engine"
        fi
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
}

CHARTS=cluster-api
[ "$USE_CAPZ" = true ] && CHARTS="$CHARTS cluster-api-provider-azure"

for PROJECT in $CHARTS ; do
    CHART="charts/$PROJECT$CHART_SUFFIX"
    [ -f $CHART/Chart.yaml ] || continue
    set_namespace_and_t
    echo ========= deploy: $CHART
    echo "        PROJECT: $PROJECT"
    echo "      NAMESPACE: $NAMESPACE"
    helm template $CHART --include-crds --namespace "$NAMESPACE" |kubectl $KUBE_CONTEXT apply -f - --server-side --force-conflicts
    echo
done


for PROJECT in $CHARTS ; do
    CHART="charts/$PROJECT$CHART_SUFFIX"
    [ -f $CHART/Chart.yaml ] || continue
    set_namespace_and_t
    echo "Waiting for ${T} controller (in $NAMESPACE namespace):"
    kubectl $KUBE_CONTEXT events -n "$NAMESPACE" --watch &
    CH_PID=$!
    kubectl $KUBE_CONTEXT -n "$NAMESPACE" wait deployment/${T}-controller-manager --for condition=Available=True  --timeout=10m
    if [ "${T}" = capz ] ; then
        kubectl $KUBE_CONTEXT -n "$NAMESPACE" wait deployment/azureserviceoperator-controller-manager --for condition=Available=True  --timeout=10m
    fi
    kill $CH_PID
    echo
done



