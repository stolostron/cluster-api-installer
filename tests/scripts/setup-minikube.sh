#!/bin/bash

# CAPI Helm Chart Testing - Minikube Setup Script
# This script sets up a minikube cluster for CAPI chart testing

set -euo pipefail

# Configuration
CLUSTER_NAME="${CLUSTER_NAME:-capi-test}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.28.0}"
MEMORY="${MEMORY:-4096}"
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-20g}"

# Auto-detect container runtime
if command -v podman &> /dev/null; then
    DRIVER="${DRIVER:-podman}"
elif command -v docker &> /dev/null; then
    DRIVER="${DRIVER:-docker}"
else
    DRIVER="${DRIVER:-docker}"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if minikube is installed
check_minikube() {
    if ! command -v minikube &> /dev/null; then
        error "minikube is not installed. Please install minikube first."
        echo "Visit: https://minikube.sigs.k8s.io/docs/start/"
        exit 1
    fi
    log "minikube found: $(minikube version --short)"
}

# Check if kubectl is installed
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        error "kubectl is not installed. Please install kubectl first."
        echo "Visit: https://kubernetes.io/docs/tasks/tools/"
        exit 1
    fi
    log "kubectl found: $(kubectl version --client --short 2>/dev/null)"
}

# Check if helm is installed
check_helm() {
    if ! command -v helm &> /dev/null; then
        error "helm is not installed. Please install helm first."
        echo "Visit: https://helm.sh/docs/intro/install/"
        exit 1
    fi
    log "helm found: $(helm version --short)"
}

# Start minikube cluster
start_cluster() {
    log "Starting minikube cluster: ${CLUSTER_NAME}"
    log "Configuration: k8s=${KUBERNETES_VERSION}, memory=${MEMORY}, cpus=${CPUS}, driver=${DRIVER}"

    minikube start \
        --profile "${CLUSTER_NAME}" \
        --driver "${DRIVER}" \
        --kubernetes-version "${KUBERNETES_VERSION}" \
        --memory "${MEMORY}" \
        --cpus "${CPUS}" \
        --disk-size "${DISK_SIZE}" \
        --wait=all \
        --delete-on-failure

    log "Cluster started successfully"
}

# Configure kubectl context
setup_kubectl() {
    log "Configuring kubectl context"
    minikube update-context --profile "${CLUSTER_NAME}"
    
    # Verify connection
    if kubectl cluster-info &> /dev/null; then
        log "kubectl configured successfully"
        kubectl cluster-info --context "${CLUSTER_NAME}"
    else
        error "Failed to configure kubectl"
        exit 1
    fi
}

# Enable essential addons
enable_addons() {
    log "Enabling minikube addons"
    
    # Enable ingress for webhook testing
    minikube addons enable ingress --profile "${CLUSTER_NAME}"
    log "✓ Ingress addon enabled"
    
    # Enable metallb for LoadBalancer services
    minikube addons enable metallb --profile "${CLUSTER_NAME}"
    log "✓ MetalLB addon enabled"
    
    # Configure MetalLB IP range
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 192.168.49.100-192.168.49.110
EOF
    log "✓ MetalLB configured with IP range"

    # Wait for addons to be ready
    log "Waiting for addons to be ready..."
    kubectl wait --namespace=ingress-nginx \
        --for=condition=ready pod \
        --selector=app.kubernetes.io/component=controller \
        --timeout=300s

    kubectl wait --namespace=metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=300s

    log "✓ All addons are ready"
}

# Verify cluster readiness
verify_cluster() {
    log "Verifying cluster readiness"
    
    # Check node status
    if kubectl get nodes --context "${CLUSTER_NAME}" | grep -q "Ready"; then
        log "✓ Node is ready"
    else
        error "Node is not ready"
        kubectl get nodes --context "${CLUSTER_NAME}"
        exit 1
    fi
    
    # Check system pods
    if kubectl get pods -n kube-system --context "${CLUSTER_NAME}" | grep -q "Running"; then
        log "✓ System pods are running"
    else
        warn "Some system pods may not be running"
        kubectl get pods -n kube-system --context "${CLUSTER_NAME}"
    fi

    # Check if we can create resources
    kubectl create namespace test-connectivity --context "${CLUSTER_NAME}" --dry-run=client -o yaml | kubectl apply -f -
    kubectl delete namespace test-connectivity --context "${CLUSTER_NAME}"
    log "✓ Can create/delete resources"
}

# Print cluster information
show_info() {
    log "Cluster setup completed successfully!"
    echo
    echo "Cluster Information:"
    echo "  Name: ${CLUSTER_NAME}"
    echo "  Kubernetes Version: ${KUBERNETES_VERSION}"
    echo "  Context: ${CLUSTER_NAME}"
    echo "  Kubeconfig: $(minikube kubeconfig --profile "${CLUSTER_NAME}")"
    echo
    echo "Useful Commands:"
    echo "  kubectl --context ${CLUSTER_NAME} get nodes"
    echo "  minikube dashboard --profile ${CLUSTER_NAME}"
    echo "  minikube tunnel --profile ${CLUSTER_NAME} (for LoadBalancer access)"
    echo "  minikube delete --profile ${CLUSTER_NAME} (to cleanup)"
    echo
}

# Cleanup function
cleanup_on_error() {
    if [ $? -ne 0 ]; then
        error "Setup failed. Cleaning up..."
        minikube delete --profile "${CLUSTER_NAME}" 2>/dev/null || true
    fi
}

# Main execution
main() {
    log "Setting up minikube cluster for CAPI chart testing"
    
    # Set trap for cleanup
    trap cleanup_on_error EXIT
    
    # Check prerequisites
    check_minikube
    check_kubectl
    check_helm
    
    # Check if cluster already exists
    if minikube profile list | grep -q "${CLUSTER_NAME}"; then
        warn "Cluster ${CLUSTER_NAME} already exists"
        read -p "Do you want to delete and recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting existing cluster..."
            minikube delete --profile "${CLUSTER_NAME}"
        else
            log "Using existing cluster"
            setup_kubectl
            verify_cluster
            show_info
            return 0
        fi
    fi
    
    # Setup cluster
    start_cluster
    setup_kubectl
    enable_addons
    verify_cluster
    show_info
    
    # Remove trap since everything succeeded
    trap - EXIT
}

# Handle script arguments
case "${1:-setup}" in
    setup)
        main
        ;;
    cleanup)
        log "Cleaning up cluster: ${CLUSTER_NAME}"
        minikube delete --profile "${CLUSTER_NAME}"
        log "Cluster deleted"
        ;;
    status)
        minikube status --profile "${CLUSTER_NAME}"
        ;;
    *)
        echo "Usage: $0 {setup|cleanup|status}"
        echo "  setup   - Create and configure minikube cluster (default)"
        echo "  cleanup - Delete the minikube cluster"
        echo "  status  - Show cluster status"
        exit 1
        ;;
esac