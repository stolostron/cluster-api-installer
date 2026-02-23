# Cluster API Operator Configuration

This directory contains configuration files for deploying the Cluster API Operator with a custom Azure Infrastructure Provider.

## Requirements

- **cluster-api-operator**: v0.24.0 or later (required for v1beta2 API support)
- **Cluster API Core**: v1.11.4 (uses v1beta2 APIs)
- **Kubernetes**: v1.28+
- **cert-manager**: v1.14.2+

## Files

- `namespace.yaml` - Creates the required namespaces (capi-operator-system, capi-system, capz-system)
- `core-provider.yaml` - Configures the Cluster API Core Provider (v1.11.4)
- `infrastructure-provider-azure.yaml` - Configures the Azure Infrastructure Provider with custom manifests

## Custom Images

This configuration uses custom images:
- **CAPZ Controller**: quay.io/mveber/cluster-api-provider-azure-rhel9:2.11.0-1
- **ASO Controller**: quay.io/mveber/azure-service-operator-rhel9:2.11.0-1
- **GitHub Release**: https://github.com/stolostron/cluster-api-provider-azure/releases/tag/v1.22.0-mce-217

## Version Compatibility

The cluster-api-operator v0.24.0+ is required to support Cluster API v1.11+ which uses the v1beta2 contract:
- v0.17.1 and earlier only support v1beta1 providers
- v0.24.0 (October 2024) added support for Cluster API v1.11.0 (v1beta2)
- v0.25.0 (January 2025) added support for Cluster API v1.12.0

## Prerequisites

When deploying on an empty Kind cluster (or any fresh Kubernetes cluster), you need to install these prerequisites first.

**Follow the manual steps below:**

### 1. cert-manager

cert-manager is required for webhook certificates used by Cluster API operators.

```bash
# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-webhook
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-cainjector
```

### 2. Cluster API Operator

Install the Cluster API Operator using Helm (recommended) or manifests.

**Option A: Using Helm (Recommended)**

```bash
# Add the Cluster API Operator helm repository
helm repo add capi-operator https://kubernetes-sigs.github.io/cluster-api-operator
helm repo update

# Install the Cluster API Operator
helm install capi-operator capi-operator/cluster-api-operator \
  --create-namespace \
  --namespace capi-operator-system \
  --version v0.24.0 \
  --wait

# Verify installation
kubectl get pods -n capi-operator-system
```

**Option B: Using Manifests**

```bash
# Install the operator
kubectl apply -f https://github.com/kubernetes-sigs/cluster-api-operator/releases/download/v0.24.0/operator-components.yaml

# Wait for operator to be ready
kubectl wait --for=condition=Available --timeout=300s -n capi-operator-system deployment/capi-operator-controller-manager
```

## Deployment Order (After Prerequisites)

1. **Create namespaces**:
   ```bash
   kubectl apply -f namespace.yaml
   ```

2. **Deploy the Core Provider**:
   ```bash
   kubectl apply -f core-provider.yaml
   ```

3. **Wait for Core Provider to be ready**:
   ```bash
   # Watch provider installation
   kubectl get coreprovider cluster-api -n capi-system -w

   # Wait for "ProviderInstalled" condition to be True
   kubectl wait --for=condition=ProviderInstalled --timeout=600s coreprovider/cluster-api -n capi-system

   # Verify deployment
   kubectl get pods -n capi-system
   ```

4. **Deploy the Azure Infrastructure Provider**:
   ```bash
   kubectl apply -f infrastructure-provider-azure.yaml
   ```

5. **Wait for Infrastructure Provider to be ready**:
   ```bash
   # Watch provider installation
   kubectl get infrastructureprovider azure -n capz-system -w

   # Wait for "ProviderInstalled" condition to be True
   kubectl wait --for=condition=ProviderInstalled --timeout=600s infrastructureprovider/azure -n capz-system

   # Verify deployments
   kubectl get pods -n capz-system
   ```

## Verification

Check the provider installation status:

```bash
# Check CoreProvider status
kubectl get coreprovider cluster-api -n capi-system -o jsonpath='{.status}' | jq

# Check InfrastructureProvider status
kubectl get infrastructureprovider azure -n capz-system -o jsonpath='{.status}' | jq

# Check if providers are installed
kubectl get pods -n capi-system
kubectl get pods -n capz-system

# View provider logs
kubectl logs -n capi-system -l cluster.x-k8s.io/provider=cluster-api
kubectl logs -n capz-system -l cluster.x-k8s.io/provider=infrastructure-azure
kubectl logs -n capz-system -l control-plane=azureserviceoperator-controller-manager
```

## Custom Release Requirements

Your custom release at https://github.com/stolostron/cluster-api-provider-azure/releases/tag/v1.22.0-mce-217 must include:

1. **metadata.yaml** - Provider metadata with version information
2. **infrastructure-components.yaml** - All CRDs, deployments, and resources (including ARO HCP CRDs)

Example metadata.yaml:
```yaml
apiVersion: clusterctl.cluster.x-k8s.io/v1alpha3
kind: Metadata
releaseSeries:
  - major: 1
    minor: 22
    contract: v1beta2
```

## Features Enabled

- **ARO**: ARO-HCP support (managed by CAPZ)
- **ASOAPI**: Azure Service Operator integration
- **AKSResourceHealth**: AKS resource health monitoring
- **CLUSTER_TOPOLOGY**: ClusterClass support (managed by Core Provider)
- **EXP_CLUSTER_RESOURCE_SET**: Cluster ResourceSet support (managed by Core Provider)
- **EXP_MACHINE_POOL**: MachinePool support (managed by Core Provider)

## Azure Service Operator

The configuration includes an additional deployment for Azure Service Operator controller manager with:
- **Custom Image**: quay.io/mveber/azure-service-operator-rhel9:2.11.0-1
- **CRD Pattern Filter**: authorization.azure.com/*, managedidentity.azure.com/*, network.azure.com/*, eventhub.azure.com/*, storage.azure.com/*, web.azure.com/*, insights.azure.com/*, keyvault.azure.com/*
- **Sync Period**: 1 hour

This ASO deployment is managed by the cluster-api-operator as an `additionalDeployment`.

## Complete Installation Example for Empty Kind Cluster

```bash
# 1. Create kind cluster
kind create cluster --name capi-test

# 2. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.2/cert-manager.yaml
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager
kubectl wait --for=condition=Available --timeout=300s -n cert-manager deployment/cert-manager-webhook

# 3. Install cluster-api-operator via Helm
helm repo add capi-operator https://kubernetes-sigs.github.io/cluster-api-operator
helm repo update
helm install capi-operator capi-operator/cluster-api-operator \
  --create-namespace \
  --namespace capi-operator-system \
  --version v0.24.0 \
  --wait

# 4. Create namespaces
kubectl apply -f namespace.yaml

# 5. Deploy Core Provider
kubectl apply -f core-provider.yaml
kubectl wait --for=condition=ProviderInstalled --timeout=600s coreprovider/cluster-api -n capi-system

# 6. Deploy Azure Infrastructure Provider
kubectl apply -f infrastructure-provider-azure.yaml
kubectl wait --for=condition=ProviderInstalled --timeout=600s infrastructureprovider/azure -n capz-system

# 7. Verify deployment
kubectl get pods -n capi-system
kubectl get pods -n capz-system
```

## Troubleshooting

### cert-manager not ready

Check cert-manager pods:
```bash
kubectl get pods -n cert-manager
kubectl logs -n cert-manager -l app=cert-manager
```

### Operator not starting

Check the operator logs:
```bash
kubectl logs -n capi-operator-system -l control-plane=controller-manager
```

### Provider fails to install

Check the operator logs for provider installation errors:
```bash
kubectl logs -n capi-operator-system -l control-plane=controller-manager
kubectl get coreprovider cluster-api -n capi-system -o yaml
kubectl get infrastructureprovider azure -n capz-system -o yaml
```

Common issues:
- **"CAPI operator is only compatible with v1beta1 providers"**: Upgrade to cluster-api-operator v0.24.0+
- **Missing metadata.yaml**: Check that the GitHub release includes metadata.yaml with correct contract version (v1beta2)

### Cannot fetch manifests from GitHub

Ensure:
1. The release v1.22.0-mce-217 exists at https://github.com/stolostron/cluster-api-provider-azure/releases
2. The release contains `metadata.yaml` and `infrastructure-components.yaml` files
3. The cluster can reach github.com (or configure a proxy if needed)

### Azure Service Operator in CrashLoopBackoff

If ASO is crashing with leader election errors:
```
I0220 06:11:31.158530       1 manager.go:107] "Lost leader due to cooperative lease release"
leaseDurationSeconds: 1
```

**Symptoms**:
- ASO pod shows `RESTARTS` constantly increasing
- Deployment shows `readyReplicas: null` and `Available: False`
- Lease has `leaseDurationSeconds: 1` and empty `holderIdentity: ""`

**Root Cause**: A corrupt pre-existing Kubernetes lease from a previous deployment or failed upgrade. The lease has `leaseDurationSeconds: 1` instead of the proper default (15s), causing constant leader election churn and preventing ASO from starting.

**Fix - Delete the Corrupt Lease** (recommended):

1. **Check if the lease is corrupt**:
   ```bash
   kubectl get lease -n capz-system controllers-leader-election-azinfra-generated -o jsonpath='{.spec.leaseDurationSeconds}'
   ```
   If this returns `1`, the lease is corrupt.

2. **Delete the corrupt lease and restart ASO**:
   ```bash
   # Delete the corrupt lease
   kubectl delete lease -n capz-system controllers-leader-election-azinfra-generated

   # Restart ASO to recreate the lease with correct defaults
   kubectl rollout restart deployment/azureserviceoperator-controller-manager -n capz-system
   ```

3. **Verify the fix**:
   ```bash
   # Wait for ASO to be ready
   kubectl rollout status deployment/azureserviceoperator-controller-manager -n capz-system

   # Check lease is now healthy (should be 15)
   kubectl get lease -n capz-system controllers-leader-election-azinfra-generated -o jsonpath='{.spec.leaseDurationSeconds}'

   # Verify holderIdentity is populated (should show pod name)
   kubectl get lease -n capz-system controllers-leader-election-azinfra-generated -o jsonpath='{.spec.holderIdentity}'
   ```
**Expected Healthy Lease**:
```yaml
spec:
  leaseDurationSeconds: 15  # Not 1!
  holderIdentity: azureserviceoperator-controller-manager-xxxxx_<uuid>  # Not empty!
  leaseTransitions: 0-2  # Low number, not 50+
```

