#!/bin/bash
# Script to install prerequisites for Cluster API Operator on an empty Kind cluster

set -e

echo "=========================================="
echo "Installing Cluster API Operator Prerequisites"
echo "=========================================="
echo ""

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "❌ ERROR: kubectl not found. Please install kubectl first."
    exit 1
fi

# Check if cluster is accessible
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ ERROR: Cannot access Kubernetes cluster. Please ensure cluster is running."
    exit 1
fi

echo "✅ kubectl found and cluster is accessible"
echo ""

# 1. Install cert-manager
echo "📦 Installing cert-manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml

echo "⏳ Waiting for cert-manager to be ready..."
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-webhook
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-cainjector

echo "✅ cert-manager installed successfully"
echo ""

# 2. Install cluster-api-operator via Helm
echo "📦 Installing cluster-api-operator..."

# Check if helm is available
if ! command -v helm &> /dev/null; then
    echo "⚠️  Helm not found. Installing cluster-api-operator using manifests instead..."
    kubectl apply -f https://github.com/kubernetes-sigs/cluster-api-operator/releases/download/v0.17.1/operator-components.yaml

    echo "⏳ Waiting for cluster-api-operator to be ready..."
    kubectl wait --for=condition=Available --timeout=300s -n capi-operator-system deployment/capi-operator-controller-manager
else
    echo "✅ Helm found, using Helm installation"

    # Add helm repository
    helm repo add capi-operator https://kubernetes-sigs.github.io/cluster-api-operator
    helm repo update

    # Install the operator
    helm install capi-operator capi-operator/cluster-api-operator \
      --create-namespace \
      --namespace capi-operator-system \
      --version v0.17.1 \
      --wait
fi

echo "✅ cluster-api-operator installed successfully"
echo ""

echo "=========================================="
echo "Prerequisites Installation Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Verify release: ./verify-release.sh"
echo "  2. Deploy provider: kubectl apply -k ."
echo "  3. Wait for provider: kubectl wait --for=condition=ProviderInstalled --timeout=600s infrastructureprovider/azure -n capz-system"
echo ""
