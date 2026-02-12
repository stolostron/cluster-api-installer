#!/bin/bash
set -e
set -o pipefail
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
    HELM_RELEASE_NAME=""
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
      aro-mockup-proxy)
        T="aro-mockup-proxy"
        HELM_RELEASE_NAME="aro-mockup-proxy"
        NAMESPACE=${NAMESPACE:-"capz-system"}
        DEPLOYMENTS[$NAMESPACE]="${T}"
        ;;
    esac
}

CHARTS=$(echo cluster-api $*|tr ' ' '\n'|sort -u|tr '\n' ' ')

if [ "$ARO_NULL_PROVISIONING" = "true" ] ; then
    CHARTS=$(echo aro-mockup-proxy $CHARTS|tr ' ' '\n'|sort -u|tr '\n' ' ')
fi

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
        kubectl $KUBE_CONTEXT get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl $KUBE_CONTEXT create namespace "$NAMESPACE" 
        # Create prerequisites for aro-mockup-proxy
        if [ "$PROJECT" = "aro-mockup-proxy" ] ; then
            KUBECONFIG_FILE=${MOCK_KUBECONFIG_FILE:-"${SCRIPT_DIR}/../aro-mockup-proxy/workload-kubeconfig.yaml"}
            if [ -f "$KUBECONFIG_FILE" ] ; then
                echo "  Creating mockup-proxy-kubeconfig secret from $KUBECONFIG_FILE"
                kubectl $KUBE_CONTEXT -n "$NAMESPACE" create secret generic mockup-proxy-kubeconfig \
                    --from-file=workload-kubeconfig.yaml="$KUBECONFIG_FILE" \
                    --dry-run=client -o yaml | kubectl $KUBE_CONTEXT -n "$NAMESPACE" apply -f -
            else
                echo "  WARNING: kubeconfig file not found at $KUBECONFIG_FILE, requestAdminCredential will fail"
            fi
        fi
        # Pass DEV_ENDPOINT to aro-mockup-proxy chart when set
        DEV_ENDPOINT_ARG=""
        if [ "$PROJECT" = "aro-mockup-proxy" -a -n "$DEV_ENDPOINT" ] ; then
            DEV_ENDPOINT_ARG="--set config.devEndpoint=$DEV_ENDPOINT"
            echo "  DEV_ENDPOINT: $DEV_ENDPOINT (hcpOpenShiftCluster requests will be forwarded)"
        fi
        echo "      HELM ARGS: --set Release.Namespace=$NAMESPACE" ${helm_add_args_a[$T]} $DEV_ENDPOINT_ARG
        HELM_NAME_ARG=""
        [ -n "$HELM_RELEASE_NAME" ] && HELM_NAME_ARG="--name-template=$HELM_RELEASE_NAME"
        helm template $HELM_NAME_ARG $CHART --include-crds --namespace "$NAMESPACE" --set "Release.Namespace=$NAMESPACE" ${helm_add_args_a[$T]} $DEV_ENDPOINT_ARG|kubectl $KUBE_CONTEXT -n "$NAMESPACE" apply -f - --server-side --force-conflicts
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
                trap "kill $CH_PID 2>/dev/null || true" EXIT
                kubectl $KUBE_CONTEXT -n "$i" wait deployment/${D} --for condition=Available=True  --timeout=10m
                kill $CH_PID 2>/dev/null || true
                echo
            done
        done
    done
fi

# Configure ARO null-provisioning mode
if [ "$ARO_NULL_PROVISIONING" = "true" ] && echo "$CHARTS" | grep -q "aro-mockup-proxy"; then
    echo "========= Configuring ARO null-provisioning mode ========="

    # Get the mockup proxy service endpoint (in capz-system namespace)
    MOCKUP_PROXY_SERVICE="aro-mockup-proxy.capz-system.svc.cluster.local:8443"
    echo "Mockup proxy service: $MOCKUP_PROXY_SERVICE"

    # Configure Azure Service Operator to use the mockup proxy
    # ASO reads these env vars from the aso-controller-settings secret via valueFrom,
    # so we patch the secret rather than the deployment to avoid value/valueFrom conflicts
    if echo "$CHARTS" | grep -q "cluster-api-provider-azure"; then
        echo "Patching aso-controller-settings secret to use mockup proxy..."

        kubectl $KUBE_CONTEXT -n capz-system patch secret aso-controller-settings \
            --type merge -p "{\"stringData\":{\"AZURE_RESOURCE_MANAGER_ENDPOINT\":\"https://$MOCKUP_PROXY_SERVICE\",\"AZURE_RESOURCE_MANAGER_AUDIENCE\":\"https://management.azure.com/\"}}" \
            || echo "Warning: Failed to patch aso-controller-settings secret"

        # Patch ASO deployment to trust the mockup proxy CA certificate and restart
        # Skip if already patched (idempotent)
        if ! kubectl $KUBE_CONTEXT -n capz-system get deployment azureserviceoperator-controller-manager -o jsonpath='{.spec.template.spec.volumes[*].name}' | grep -q mockup-proxy-ca; then
            echo "Patching ASO deployment to trust mockup proxy CA..."
            kubectl $KUBE_CONTEXT -n capz-system patch deployment azureserviceoperator-controller-manager --type=json -p='[
              {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"mockup-proxy-ca","secret":{"secretName":"aro-mockup-proxy-tls","items":[{"key":"ca.crt","path":"ca.crt"}]}}},
              {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"mockup-proxy-ca","mountPath":"/etc/ssl/certs/aro-mockup-proxy-ca.crt","subPath":"ca.crt","readOnly":true}},
              {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"SSL_CERT_FILE","value":"/etc/ssl/certs/aro-mockup-proxy-ca.crt"}}
            ]'
        else
            echo "ASO deployment already patched with mockup proxy CA, skipping"
        fi

        echo "✓ Azure Service Operator configured to use mockup proxy"
        echo "  ARM endpoint: https://$MOCKUP_PROXY_SERVICE"
    fi

    echo "========= ARO null-provisioning mode configured ========="
fi


