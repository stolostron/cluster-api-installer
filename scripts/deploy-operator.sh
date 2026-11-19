#!/bin/bash
set -e
DO_INIT_KIND=${INIT_KIND:-true}
DO_DEPLOY=${DO_DEPLOY:-true}
DO_CHECK=${DO_CHECK:-true}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
declare -A DEPLOYMENTS=()

[ -s ./replace-params ] && . ./replace-params

if [ "$USE_KIND" = true ] ; then
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
    T=""
    DEPL_NAME=""
    case "$PROJECT" in
      cluster-api-operator)
        T="capi-operator"
        #DEPL_NAME="cluster-api-operator-deployment"
        NAMESPACE=${NAMESPACE:-"capi-operator-system"}
        DEPLOYMENTS[$NAMESPACE]="cluster-api-operator"
      ;;
      cluster-api)
        T="capi"
        DEPL_NAME="core-provider"
        NAMESPACE=${NAMESPACE:-"capi-system"}
        DEPLOYMENTS[$NAMESPACE]="${T}-controller-manager"
        if [ "$USE_KIND" != true -a "$USE_K8S" != true ] ; then
            DEPLOYMENTS[$NAMESPACE]="${DEPLOYMENTS[$NAMESPACE]} mce-capi-webhook-config"
        fi
        ;;
      cluster-api-provider-azure)
        T="capz"
        DEPL_NAME="infrastructure-provider-azure"
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
    DEPL_YAML=$(realpath "${SCRIPT_DIR}/../cluster-api-operator/${DEPL_NAME}.yaml")
}

CHARTS=$(echo $*|tr ' ' '\n'|sort -u|grep -vE '^(cluster-api-operator|cluster-api)$'|tr '\n' ' ')
CHARTS="cluster-api $CHARTS"
HELMS=$(helm list --all-namespaces --no-headers |sed -e 's/[[:space:]].*//')

if (echo $HELMS|grep -q '\<capi-operator\>'); then
    echo "✅ capi-operator is installed"
else
    CLUSTER_API_OPERATOR_VERSION=${CLUSTER_API_OPERATOR_VERSION:-v0.24.0}
    PROJECT=cluster-api-operator
    set_namespace_and_t
    echo "✅ installing cluster-api-operator version=$CLUSTER_API_OPERATOR_VERSION into namespace $NAMESPACE"
    # Add helm repository
    helm repo add capi-operator https://kubernetes-sigs.github.io/cluster-api-operator
    helm repo update
    
    # Install the operator
    helm install capi-operator capi-operator/cluster-api-operator \
      --create-namespace \
      --namespace "$NAMESPACE" \
      --version "$CLUSTER_API_OPERATOR_VERSION" \
      --set fullnameOverride=cluster-api-operator \
      --set nameOverride=cluster-api-operator \
      --wait
fi


if [ "$DO_DEPLOY" = true ] ; then
    for PROJECT in $CHARTS ; do
        set_namespace_and_t
        echo ========= deploy: $DEPL_YAML "using context: $KUBE_CONTEXT"
        echo "        PROJECT: $PROJECT"
        echo "      NAMESPACE: $NAMESPACE"
        echo
        [ -z "$DEPL_NAME" ] && {
            echo "    !!!!!!!!! SKIP DEPLOY: no DEPL_NAME defined"
            continue
        }
        [ -f "$DEPL_YAML" ] || {
            echo "    !!!!!!!!! SKIP DEPLOY: $DEPL_YAML"
            continue
        }
        kubectl $KUBE_CONTEXT create ns "$NAMESPACE" || true
        kubectl $KUBE_CONTEXT apply -f "$DEPL_YAML"
    done
fi

if [ "$DO_CHECK" = true ] ; then
    for PROJECT in cluster-api-operator $CHARTS ; do
        set_namespace_and_t
        [ -z "$T" ] && {
            continue
        }

        # Check if provider resource is healthy before checking deployments
        if [ -f "$DEPL_YAML" ]; then
            RESOURCE_KIND=$(kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.kind}' 2>/dev/null || true)
            RESOURCE_NAME=$(kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.metadata.name}' 2>/dev/null || true)
            RESOURCE_NS=$(kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.metadata.namespace}' 2>/dev/null || true)

            if [[ "$RESOURCE_KIND" == "CoreProvider" || "$RESOURCE_KIND" == "InfrastructureProvider" || "$RESOURCE_KIND" == "BootstrapProvider" || "$RESOURCE_KIND" == "ControlPlaneProvider" ]]; then
                echo "Checking $RESOURCE_KIND/$RESOURCE_NAME status in $RESOURCE_NS namespace:"

                # Wait for ProviderInstalled condition to be True
                MAX_ATTEMPTS=60
                ATTEMPT=0
                while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
                    PROVIDER_STATUS=$(kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.status.conditions[?(@.type=="ProviderInstalled")].status}' 2>/dev/null || echo "Unknown")
                    PROVIDER_REASON=$(kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.status.conditions[?(@.type=="ProviderInstalled")].reason}' 2>/dev/null || echo "Unknown")
                    PROVIDER_MESSAGE=$(kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.status.conditions[?(@.type=="ProviderInstalled")].message}' 2>/dev/null || echo "")

                    if [ "$PROVIDER_STATUS" = "True" ]; then
                        echo "✅ $RESOURCE_KIND/$RESOURCE_NAME is installed successfully"
                        break
                    elif [ "$PROVIDER_STATUS" = "False" ]; then
                        echo "❌ $RESOURCE_KIND/$RESOURCE_NAME installation failed:"
                        echo "   Reason: $PROVIDER_REASON"
                        echo "   Message: $PROVIDER_MESSAGE"
                        echo ""
                        echo "Full status:"
                        kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o jsonpath='{.status}' | jq
                        exit 1
                    fi

                    echo "⏳ Waiting for $RESOURCE_KIND/$RESOURCE_NAME to be installed... (attempt $((ATTEMPT+1))/$MAX_ATTEMPTS, status: $PROVIDER_STATUS)"
                    sleep 10
                    ATTEMPT=$((ATTEMPT+1))
                done

                if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
                    echo "❌ Timeout waiting for $RESOURCE_KIND/$RESOURCE_NAME to be installed"
                    kubectl $KUBE_CONTEXT get -f "$DEPL_YAML" -o yaml
                    exit 1
                fi
                echo ""
            fi
        fi

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


