# Quick Start Guide

This guide walks you through deploying Cluster API with custom Azure provider on an empty Kind cluster.

## One-Command Installation

```bash
# 1. Install prerequisites (cert-manager + cluster-api-operator)
./install-prerequisites.sh

# 2. Deploy Azure Infrastructure Provider
kubectl apply -k .

# 3. Wait for provider to be ready
kubectl wait --for=condition=ProviderInstalled --timeout=600s infrastructureprovider/azure -n capz-system
```

## Step-by-Step Installation

### Step 1: Create Kind Cluster (if needed)

```bash
kind create cluster --name capi-test
```

### Step 2: Install Prerequisites

```bash
./install-prerequisites.sh
```

This will install:
- cert-manager (required for webhooks)
- cluster-api-operator (via Helm or manifests)

### Step 3: Verify GitHub Release (Optional)

```bash
./verify-release.sh
```

### Step 4: Deploy Azure Infrastructure Provider

```bash
kubectl apply -k .
```

This will:
- Create namespaces (capi-operator-system, capz-system)
- Deploy InfrastructureProvider custom resource
- Trigger cluster-api-operator to fetch manifests from GitHub release
- Install CAPZ controller with custom image
- Install ASO controller as additional deployment

### Step 5: Wait for Installation

```bash
# Watch the installation progress
kubectl get infrastructureprovider azure -n capz-system -w

# Or wait for completion
kubectl wait --for=condition=ProviderInstalled --timeout=600s infrastructureprovider/azure -n capz-system
```

### Step 6: Verify Installation

```bash
# Check all pods are running
kubectl get pods -n capz-system

# Verify CAPZ controller
kubectl get deployment -n capz-system capz-controller-manager

# Verify ASO controller
kubectl get deployment -n capz-system azureserviceoperator-controller-manager

# Check CRDs are installed (including ARO HCP CRDs)
kubectl get crds | grep cluster.x-k8s.io
kubectl get crds | grep infrastructure.cluster.x-k8s.io
```

## Troubleshooting

### Prerequisites installation failed

Check the logs:
```bash
kubectl get pods -n cert-manager
kubectl get pods -n capi-operator-system
```

### Provider installation stuck

Check operator logs:
```bash
kubectl logs -n capi-operator-system -l control-plane=controller-manager
```

Check provider status:
```bash
kubectl get infrastructureprovider azure -n capz-system -o yaml
```

### Cannot fetch from GitHub

Ensure:
1. Cluster has internet access
2. GitHub release exists: https://github.com/stolostron/cluster-api-provider-azure/releases/tag/v1.22.0-mce-217
3. Release contains metadata.yaml and infrastructure-components.yaml

## What Gets Installed

### Custom Images Used

- **CAPZ Controller**: `quay.io/mveber/cluster-api-provider-azure-rhel9:2.11.0-1`
- **ASO Controller**: `quay.io/mveber/azure-service-operator-rhel9:2.11.0-1`

### Components Deployed

1. **cert-manager** (namespace: cert-manager)
   - cert-manager controller
   - webhook
   - cainjector

2. **cluster-api-operator** (namespace: capi-operator-system)
   - operator controller manager

3. **Azure Infrastructure Provider** (namespace: capz-system)
   - CAPZ controller manager
   - Azure Service Operator controller manager

### Custom Resources

The installation includes custom CRDs from the v1.22.0-mce-217 release:
- Standard CAPZ CRDs (AzureCluster, AzureMachine, etc.)
- ARO HCP CRDs (AROControlPlane, etc.)
- All ASO CRDs as defined in the crd-pattern

## Next Steps

After installation, you can:

1. **Create an Azure cluster** using ClusterAPI manifests
2. **Configure Azure credentials** as a secret
3. **Deploy workload clusters** on Azure

See the main README.md for detailed configuration options.
