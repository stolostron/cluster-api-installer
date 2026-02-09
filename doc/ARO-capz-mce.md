# Creating ARO HCP Clusters with CAPZ in Multi-Cluster Engine (MCE)

This guide explains how to provision Azure Red Hat OpenShift (ARO) Hosted Control Plane (HCP) clusters using Cluster API Provider Azure (CAPZ) within Red Hat Advanced Cluster Management (ACM) with Multi-Cluster Engine (MCE).

> **Note**: In MCE, all Cluster API controllers (CAPI, CAPZ, and ASO) run in the `multicluster-engine` namespace, unlike standalone CAPZ deployments where they run in separate namespaces (`capi-system`, `capz-system`).

## Table of Contents

- [Prerequisites](#prerequisites)
- [Configure MCE Component Toggles](#configure-mce-component-toggles)
- [Enable CAPI and CAPZ](#enable-capi-and-capz)
- [Verify HyperShift is Disabled](#verify-hypershift-is-disabled)
- [Azure Credentials Configuration](#azure-credentials-configuration)
- [Creating the ARO HCP Cluster](#creating-the-aro-hcp-cluster)
- [Verify Cluster Creation](#verify-cluster-creation)
- [Delete ARO HCP Cluster](#delete-aro-hcp-cluster)
- [Troubleshooting](#troubleshooting)

## Prerequisites

Before provisioning ARO HCP clusters with CAPZ, ensure you have:

1. **ACM/MCE Installed**: Multi-Cluster Engine installed on your hub cluster
   ```bash
   oc get mce multiclusterengine -n multicluster-engine
   ```

2. **Azure Subscription**: Valid Azure subscription with permissions to create ARO HCP resources

3. **CLI Tools**:
   - `oc` (OpenShift CLI)
   - `kubectl`
   - `clusterctl` (Cluster API CLI)
   - `jq` (JSON processor)

4. **Azure Service Operator (ASO)**: ASO v2 deployed automatically when CAPZ is enabled (runs in multicluster-engine namespace)

5. **Network Connectivity**: Hub cluster must have network access to Azure management APIs

## Configure MCE Component Toggles

MCE uses component toggles to enable/disable various cluster lifecycle features. For ARO HCP with CAPZ, you need the correct toggle configuration.

### Check Current Toggle Settings

View the current state of all MCE components:

```bash
oc get multiclusterengine multiclusterengine -o json | \
  jq -r '.spec.overrides.components[] | [.name, .enabled] | @tsv' | \
  column -t -s $'\t' -N "COMPONENT,ENABLED"
```

**Expected output:**
```
COMPONENT                                ENABLED
local-cluster                            true
assisted-service                         true
cluster-lifecycle                        true
cluster-manager                          true
discovery                                true
hive                                     true
server-foundation                        true
cluster-proxy-addon                      true
hypershift-local-hosting                 false
hypershift                               false
managedserviceaccount                    true
cluster-api                              false  ← Must be TRUE
cluster-api-provider-aws                 false
cluster-api-provider-azure-preview       true   ← Must be TRUE
cluster-api-provider-metal3              false
cluster-api-provider-openshift-assisted  false
image-based-install-operator             false
console-mce                              true
```

### Required Toggle Configuration for ARO HCP

For ARO HCP clusters with CAPZ, the following components **MUST** be configured:

| Component | Required State | Purpose |
|-----------|---------------|---------|
| `cluster-api` | **TRUE** | Core Cluster API functionality |
| `cluster-api-provider-azure-preview` | **TRUE** | CAPZ provider for Azure |
| `hypershift` | **FALSE** | Conflicts with CAPI - must be disabled |
| `hypershift-local-hosting` | **FALSE** | Conflicts with CAPI - must be disabled |

## Enable CAPI and CAPZ

### Enable Cluster API (CAPI)

Enable the core Cluster API component:

```bash
oc patch mce multiclusterengine --type=merge -p "{\"spec\":{\"overrides\":{\"components\":$(oc get mce multiclusterengine -o json | jq -c '.spec.overrides.components | map(if .name == "cluster-api" then .enabled = true else . end)')}}}"
```

**Verify CAPI is enabled:**
```bash
oc get mce multiclusterengine -o json | \
  jq -r '.spec.overrides.components[] | select(.name == "cluster-api") | [.name, .enabled] | @tsv'
```

**Expected output:**
```
cluster-api	true
```

### Enable CAPZ (Cluster API Provider Azure)

Enable the Azure provider component:

```bash
oc patch mce multiclusterengine --type=merge -p "{\"spec\":{\"overrides\":{\"components\":$(oc get mce multiclusterengine -o json | jq -c '.spec.overrides.components | map(if .name == "cluster-api-provider-azure-preview" then .enabled = true else . end)')}}}"
```

**Verify CAPZ is enabled:**
```bash
oc get mce multiclusterengine -o json | \
  jq -r '.spec.overrides.components[] | select(.name == "cluster-api-provider-azure-preview") | [.name, .enabled] | @tsv'
```

**Expected output:**
```
cluster-api-provider-azure-preview	true
```

### Wait for Operators to Deploy

After enabling CAPI and CAPZ, wait for the operators to be ready. In MCE, all controllers (CAPI, CAPZ, and ASO) run in the `multicluster-engine` namespace:

```bash
# Check all CAPI-related controllers in multicluster-engine namespace
oc get deployment -n multicluster-engine | grep -E "(capi|capz|azureserviceoperator)"
```

**Expected output:**
```
NAME                                      READY   UP-TO-DATE   AVAILABLE   AGE
azureserviceoperator-controller-manager   1/1     1            1           2m
capz-controller-manager                   1/1     1            1           2m
capi-controller-manager                   1/1     1            1           2m
```

**Note**: The CAPZ deployment includes both CAPZ and ASO controllers. ASO is automatically deployed when CAPZ is enabled.

## Verify HyperShift is Disabled

**IMPORTANT**: HyperShift and Cluster API cannot run simultaneously. Verify HyperShift components are disabled:

```bash
oc get mce multiclusterengine -o json | \
  jq -r '.spec.overrides.components[] | select(.name | startswith("hypershift")) | [.name, .enabled] | @tsv' | \
  column -t -s $'\t' -N "COMPONENT,ENABLED"
```

**Expected output:**
```
COMPONENT                 ENABLED
hypershift-local-hosting  false
hypershift                false
```

### Disable HyperShift (if needed)

If HyperShift components are enabled, disable them:

```bash
# Disable hypershift
oc patch mce multiclusterengine --type=merge -p "{\"spec\":{\"overrides\":{\"components\":$(oc get mce multiclusterengine -o json | jq -c '.spec.overrides.components | map(if .name == "hypershift" then .enabled = false else . end)')}}}"

# Disable hypershift-local-hosting
oc patch mce multiclusterengine --type=merge -p "{\"spec\":{\"overrides\":{\"components\":$(oc get mce multiclusterengine -o json | jq -c '.spec.overrides.components | map(if .name == "hypershift-local-hosting" then .enabled = false else . end)')}}}"
```

**Verify HyperShift operators are removed:**
```bash
oc get deployment -n hypershift
```

**Expected output:**
```
No resources found in hypershift namespace.
```

## Azure Credentials Configuration

### Create Azure Service Principal

Create a service principal with permissions to manage ARO HCP resources:

```bash
az ad sp create-for-rbac \
  --name "aro-hcp-capz-sp" \
  --role "Contributor" \
  --scopes "/subscriptions/<SUBSCRIPTION_ID>"
```

**Save the output** - you'll need:
- `appId` (Client ID)
- `password` (Client Secret)
- `tenant` (Tenant ID)

### Create Azure Credential Secret

Create a Kubernetes secret with Azure credentials for ASO:

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: aso-credential
  namespace: default
stringData:
  AZURE_SUBSCRIPTION_ID: "<YOUR_SUBSCRIPTION_ID>"
  AZURE_TENANT_ID: "<YOUR_TENANT_ID>"
  AZURE_CLIENT_ID: "<YOUR_CLIENT_ID>"
  AZURE_CLIENT_SECRET: "<YOUR_CLIENT_SECRET>"
EOF
```

**Verify secret creation:**
```bash
oc get secret aso-credential -n default
```

## Creating the ARO HCP Cluster

### 1. Create Cluster Namespace

```bash
export CLUSTER_NAME="aro-hcp-cluster"
export CLUSTER_NAMESPACE="aro-clusters"

oc create namespace ${CLUSTER_NAMESPACE}
```

### 2. Define Cluster Resources

Create a file `aro-hcp-cluster.yaml` with your cluster definition:

```yaml
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: aro-hcp-cluster
  namespace: aro-clusters
  labels:
    cluster.x-k8s.io/cluster-name: aro-hcp-cluster
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
        - 10.128.0.0/14
    services:
      cidrBlocks:
        - 172.30.0.0/16
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: AROControlPlane
    name: aro-hcp-cluster
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: AROCluster
    name: aro-hcp-cluster
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AROCluster
metadata:
  name: aro-hcp-cluster
  namespace: aro-clusters
spec:
  location: eastus
  resourceGroupName: aro-hcp-cluster-rg
  subscriptionID: "<YOUR_SUBSCRIPTION_ID>"
  resources:
    # Infrastructure resources will be defined here
    # See ARO-capz.md for complete resource definitions
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: AROControlPlane
metadata:
  name: aro-hcp-cluster
  namespace: aro-clusters
spec:
  location: eastus
  subscriptionID: "<YOUR_SUBSCRIPTION_ID>"
  version: "4.20.0"
  resources:
    # Control plane resources will be defined here
    # See ARO-capz.md for complete resource definitions
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachinePool
metadata:
  name: aro-hcp-cluster-workers
  namespace: aro-clusters
spec:
  clusterName: aro-hcp-cluster
  replicas: 3
  template:
    spec:
      bootstrap:
        dataSecretName: ""
      clusterName: aro-hcp-cluster
      infrastructureRef:
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
        kind: AROMachinePool
        name: aro-hcp-cluster-workers
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AROMachinePool
metadata:
  name: aro-hcp-cluster-workers
  namespace: aro-clusters
spec:
  resources:
    # Node pool resources will be defined here
    # See ARO-capz.md for complete resource definitions
```

### 3. Apply Cluster Configuration

```bash
oc apply -f aro-hcp-cluster.yaml
```

### 4. Monitor Cluster Creation

Watch the cluster provisioning progress:

```bash
# Watch Cluster API resources
clusterctl describe cluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} --show-conditions=all

# Watch ASO resources
oc get HcpOpenShiftCluster,HcpOpenShiftClustersNodePool -n ${CLUSTER_NAMESPACE}

# Check CAPZ controller logs (in multicluster-engine namespace)
oc logs -n multicluster-engine deployment/capz-controller-manager -f
```

**Cluster provisioning typically takes 15-20 minutes.**

## Verify Cluster Creation

### Check Cluster Status

```bash
# Check CAPI Cluster status
oc get cluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE}

# Check detailed status with conditions
clusterctl describe cluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} --show-conditions=all
```

**Expected output when ready:**
```
NAME              CLUSTERCLASS   AVAILABLE   CP AVAILABLE   AGE
aro-hcp-cluster                  True        True           20m
```

### Verify Infrastructure Resources

```bash
# Check AROCluster
oc get arocluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE}

# Check AROControlPlane
oc get arocontrolplane ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE}

# Check AROMachinePool
oc get aromachinepool -n ${CLUSTER_NAMESPACE}
```

### Verify ASO Resources

```bash
# Check HCP cluster in Azure
oc get HcpOpenShiftCluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE}

# Check node pools
oc get HcpOpenShiftClustersNodePool -n ${CLUSTER_NAMESPACE}
```

### Get Cluster Kubeconfig

The kubeconfig is automatically created when the cluster is ready:

```bash
# Get kubeconfig secret
oc get secret ${CLUSTER_NAME}-kubeconfig -n ${CLUSTER_NAMESPACE} -o jsonpath='{.data.value}' | base64 -d > ${CLUSTER_NAME}-kubeconfig

# Test connection
export KUBECONFIG=${CLUSTER_NAME}-kubeconfig
oc get nodes
```

### Access OpenShift Console

Get the console URL from the control plane status:

```bash
oc get arocontrolplane ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} -o jsonpath='{.status.consoleURL}'
```

## Delete ARO HCP Cluster

### Delete Cluster Resources

Delete the cluster and all related resources:

```bash
oc delete cluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE}
```

### Monitor Deletion

Watch the deletion progress:

```bash
# Watch cluster deletion
oc get cluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} -w

# Check ASO resources are being deleted
oc get HcpOpenShiftCluster,HcpOpenShiftClustersNodePool -n ${CLUSTER_NAMESPACE}

# Monitor CAPZ controller logs (in multicluster-engine namespace)
oc logs -n multicluster-engine deployment/capz-controller-manager -f | grep ${CLUSTER_NAME}
```

**Cluster deletion typically takes 10-15 minutes.**

### Verify Complete Deletion

Ensure all resources are removed:

```bash
# Check CAPI resources
oc get cluster,arocontrolplane,arocluster,aromachinepool -n ${CLUSTER_NAMESPACE}

# Check ASO resources
oc get HcpOpenShiftCluster,HcpOpenShiftClustersNodePool -n ${CLUSTER_NAMESPACE}

# Verify Azure resources are deleted (use Azure Portal or CLI)
az aro show --name ${CLUSTER_NAME} --resource-group ${CLUSTER_NAME}-rg
```

## Troubleshooting

### Check MCE Component Status

Verify MCE components are in the expected state:

```bash
# Full component status
oc get mce multiclusterengine -o yaml | yq '.spec.overrides.components'

# Check specific component
oc get mce multiclusterengine -o json | \
  jq -r '.spec.overrides.components[] | select(.name == "cluster-api")'
```

### Check Controller Logs

View logs from CAPI, CAPZ, and ASO controllers. In MCE, all controllers run in the `multicluster-engine` namespace:

```bash
# CAPI controller logs
oc logs -n multicluster-engine deployment/capi-controller-manager --tail=100

# CAPZ controller logs
oc logs -n multicluster-engine deployment/capz-controller-manager --tail=100 | grep ${CLUSTER_NAME}

# ASO controller logs
oc logs -n multicluster-engine deployment/azureserviceoperator-controller-manager --tail=100
```

### Common Issues

#### CAPI Controllers Not Starting

**Symptom**: CAPI or CAPZ deployments not creating pods

**Solution**:
```bash
# Verify toggle is enabled
oc get mce multiclusterengine -o json | \
  jq -r '.spec.overrides.components[] | select(.name | contains("cluster-api"))'

# Check for conflicting HyperShift
oc get deployment -n hypershift

# Force MCE reconciliation
oc annotate mce multiclusterengine force-reconcile=$(date +%s) --overwrite
```

#### HyperShift Conflict

**Symptom**: Both HyperShift and CAPI controllers running simultaneously

**Solution**:
```bash
# Disable HyperShift components
oc patch mce multiclusterengine --type=merge -p '{"spec":{"overrides":{"components":[{"name":"hypershift","enabled":false},{"name":"hypershift-local-hosting","enabled":false}]}}}'

# Wait for HyperShift to be removed
oc wait --for=delete namespace/hypershift --timeout=5m
```

#### Azure Authentication Errors

**Symptom**: ASO resources failing with authentication errors

**Solution**:
```bash
# Verify Azure credentials secret
oc get secret aso-credential -n ${CLUSTER_NAMESPACE} -o yaml

# Test Azure connectivity
oc run azure-cli --rm -it --image=mcr.microsoft.com/azure-cli -- bash
# Inside pod: az login --service-principal --username <CLIENT_ID> --password <CLIENT_SECRET> --tenant <TENANT_ID>
```

#### Cluster Stuck in Provisioning

**Symptom**: Cluster status shows provisioning for extended period

**Solution**:
```bash
# Check detailed conditions
clusterctl describe cluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} --show-conditions=all

# Check infrastructure status
oc get arocluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} -o yaml | yq '.status'

# Check ASO resource status
oc get HcpOpenShiftCluster ${CLUSTER_NAME} -n ${CLUSTER_NAMESPACE} -o yaml | yq '.status.conditions'

# Check for errors in events
oc get events -n ${CLUSTER_NAMESPACE} --sort-by='.lastTimestamp' | grep ${CLUSTER_NAME}
```

### Enable Debug Logging

Increase verbosity for troubleshooting. In MCE, all controllers run in the `multicluster-engine` namespace:

```bash
# Increase CAPZ controller log level
oc patch deployment capz-controller-manager -n multicluster-engine --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "-v=4"}]'

# Increase CAPI controller log level
oc patch deployment capi-controller-manager -n multicluster-engine --type=json \
  -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "-v=4"}]'
```

## Additional Resources

- [ARO HCP Resource Configuration (ARO-capz.md)](./ARO-capz.md) - Detailed resource definitions
- [CAPZ Documentation](https://capz.sigs.k8s.io/) - Cluster API Provider Azure docs
- [MCE Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/multicluster_engine/index) - Multi-Cluster Engine
- [Azure Service Operator](https://azure.github.io/azure-service-operator/) - ASO v2 documentation
- [ARO HCP Documentation](https://learn.microsoft.com/en-us/azure/openshift/) - Azure Red Hat OpenShift

## Support

For issues and questions:
- **CAPZ Issues**: [GitHub Issues](https://github.com/kubernetes-sigs/cluster-api-provider-azure/issues)
- **MCE Issues**: Red Hat Support Portal
- **ARO Support**: Azure Support
