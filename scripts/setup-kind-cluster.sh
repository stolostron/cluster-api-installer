#!/bin/bash
set -e

# This script sets up a kind cluster with cert-manager
# Can be used standalone or called by other scripts
#
# Usage:
#   ./setup-kind-cluster.sh [cluster-name]
#
# Environment variables:
#   KIND_CLUSTER_NAME - Name of the kind cluster (default: aso2)

KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-${1:-aso2}}
HELM_INSTALL_TIMEOUT=${HELM_INSTALL_TIMEOUT:-10m}
KIND_NODE_IMAGE=${KIND_NODE_IMAGE:-kindest/node:v1.31.14}

if ! (kind get clusters 2>/dev/null|grep -q '^'"$KIND_CLUSTER_NAME"'$') ; then
    SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [ -z "$KIND_CFG_NAME" ] ; then
        if [ -n "$DOCKER_SECRETS" ] ; then
            KIND_CFG_NAME="$SCRIPT_DIR/kind-config-$KIND_CLUSTER_NAME.yaml"
cat << EOF > "$KIND_CFG_NAME"
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraMounts:
  - hostPath: $DOCKER_SECRETS
    containerPath: /var/lib/kubelet/config.json
EOF
        fi
    fi
    KIND_OPTS="" 
    if [ -f "$KIND_CFG_NAME" ] ; then
        KIND_OPTS="$KIND_OPTS --config=$KIND_CFG_NAME"
    fi
    kind create cluster --name "$KIND_CLUSTER_NAME" --image="$KIND_NODE_IMAGE" $KIND_OPTS
    helm repo add jetstack https://charts.jetstack.io --force-update
    helm repo update
    helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --set crds.enabled=true --wait --timeout $HELM_INSTALL_TIMEOUT
fi
