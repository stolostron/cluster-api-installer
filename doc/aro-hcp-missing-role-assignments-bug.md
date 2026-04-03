# ARO HCP Bug: Cluster Fails When Role Assignments Are Not Ready

## Problem

When an ARO HCP cluster is created via CAPZ/ASO, the `HcpOpenShiftCluster` resource
can transition to `Failed` / `Error` state if the role assignments for the managed
identities are not yet propagated in Azure at the time the cluster is provisioned.

The ARM inflight check `managed-service-identity-inflight` validates that the
service-managed-identity has the required permissions over data plane identities
(e.g. `dp-disk-csi-driver`, `dp-file-csi-driver`, `dp-image-registry`). If the
role assignments are missing or not yet propagated, the cluster goes to error state
with message:

```
inflight check 'managed-service-identity-inflight' failed: service managed identity
lacks required actions over one or more data plane identities:
  - not allowed: Microsoft.ManagedIdentity/userAssignedIdentities/read,
    Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/read,
    Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write
```

Once in error state, the cluster cannot be updated:
```
Cluster '<id>' is in state 'error', can't update
```

## Steps to Reproduce

Tested by Marek Veber on 2026-04-02 in subscription `b23756f7-4594-40a3-980f-10bb6168fc20`,
resource group `mv1-tests-resgroup`.

### 1. Deploy infrastructure without role assignments

Deploy the AROCluster resources (resource group, VNet, subnets, NSG, key vault,
user-assigned identities) but **remove all `RoleAssignment` resources** from
`AROCluster.spec.resources[]`.

Verify all infrastructure is ready and no role assignments exist:

```bash
$ oc get -A roleassignments.authorization.azure.com,userassignedidentities.managedidentity.azure.com,vaults.keyvault.azure.com,virtualnetworkssubnets.network.azure.com,networksecuritygroups.network.azure.com,virtualnetworks.network.azure.com,resourcegroups.resources.azure.com
NAMESPACE                   NAME                                                                                              READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-cloud-controller-manager-1b425d   True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-cloud-network-config-1b425d       True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-cluster-api-azure-1b425d          True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-control-plane-1b425d              True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-disk-csi-driver-1b425d            True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-file-csi-driver-1b425d            True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-image-registry-1b425d             True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-ingress-1b425d                    True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-cp-kms-1b425d                        True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-dp-disk-csi-driver-1b425d            True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-dp-file-csi-driver-1b425d            True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-dp-image-registry-1b425d             True               Succeeded
capz-test-20260402-170951   userassignedidentity.managedidentity.azure.com/mv1-mv1-tests-service-managed-identity-1b425d      True               Succeeded

NAMESPACE                   NAME                                    READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   vault.keyvault.azure.com/mv1-tests-kv   True               Succeeded

NAMESPACE                   NAME                                                                                  READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   virtualnetworkssubnet.network.azure.com/mv1-tests-vnet-mv1-tests-integration-subnet   True               Succeeded
capz-test-20260402-170951   virtualnetworkssubnet.network.azure.com/mv1-tests-vnet-mv1-tests-subnet               True               Succeeded

NAMESPACE                   NAME                                                   READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   networksecuritygroup.network.azure.com/mv1-tests-nsg   True               Succeeded

NAMESPACE                   NAME                                              READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   virtualnetwork.network.azure.com/mv1-tests-vnet   True               Succeeded

NAMESPACE                   NAME                                                   READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   resourcegroup.resources.azure.com/mv1-tests-resgroup   True               Succeeded
```

Note: no `roleassignment` resources appear in the output - all infrastructure is ready
but permissions are not assigned.

### 2. Create the HcpOpenShiftCluster

Apply the `AROControlPlane` with the `HcpOpenShiftCluster` resource. Wait ~10 minutes
for ARM to run inflight checks.

### 3. Observe the failure

```bash
$ oc get hcpopenshiftclusters -A
NAMESPACE                   NAME        READY   SEVERITY   REASON                  MESSAGE
capz-test-20260402-170951   mv1-tests   False   Error      InvalidRequestContent   Cluster '...' is in state 'error', can't update

$ az rest --url "/subscriptions/b23756f7-4594-40a3-980f-10bb6168fc20/resourceGroups/mv1-tests-resgroup/providers/Microsoft.RedHatOpenShift/hcpOpenShiftClusters/mv1-tests?api-version=2025-12-23-preview" \
  | grep provisioningState
    "provisioningState": "Failed",
```

## Workaround

### 1. Deploy the missing role assignments

Apply the role assignments externally (outside of `AROCluster.spec.resources[]`):

```bash
$ oc apply -f aro2.yaml
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-cluster-api-azure-1b425d-hcpclusterapiproviderroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-clusterapiazuremi created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-kms-1b425d-keyvaultcryptouserroleid-keyvault created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-kmsmi created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-control-plane-1b425d-hcpcontrolplaneoperatorroleid-vnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-control-plane-1b425d-hcpcontrolplaneoperatorroleid-nsg created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-controlplanemi created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-cloud-controller-manager-1b425d-cloudcontrollermanagerroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-cloud-controller-manager-1b425d-cloudcontrollermanagerroleid-nsg created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-cloudcontrollermanagermi created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-ingress-1b425d-ingressoperatorroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-ingressmi created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-diskcsidrivermi created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-file-csi-driver-1b425d-filestorageoperatorroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-file-csi-driver-1b425d-filestorageoperatorroleid-nsg created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-filecsidrivermi created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-imageregistrymi created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-cloud-network-config-1b425d-networkoperatorroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-cp-cloud-network-config-1b425d-networkoperatorroleid-vnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-cloudnetworkconfigmi created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-federatedcredentialsroleid-dpdiskcsidrivermi created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-federatedcredentialsroleid-dpfilecsidrivermi created
roleassignment.authorization.azure.com/mv1-mv1-tests-dp-file-csi-driver-1b425d-filestorageoperatorroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-dp-file-csi-driver-1b425d-filestorageoperatorroleid-nsg created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-federatedcredentialsroleid-dpimageregistrymi created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-vnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-subnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-intsubnet created
roleassignment.authorization.azure.com/mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-nsg created
```

### 2. Wait for all role assignments to be ready

```bash
$ oc get -A roleassignments
NAMESPACE                   NAME                                                                                         READY   SEVERITY   REASON      MESSAGE
capz-test-20260402-170951   mv1-mv1-tests-cp-cloud-controller-manager-1b425d-cloudcontrollermanagerroleid-nsg            True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-cloud-controller-manager-1b425d-cloudcontrollermanagerroleid-subnet         True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-cloud-network-config-1b425d-networkoperatorroleid-subnet                    True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-cloud-network-config-1b425d-networkoperatorroleid-vnet                      True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-cluster-api-azure-1b425d-hcpclusterapiproviderroleid-subnet                 True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-control-plane-1b425d-hcpcontrolplaneoperatorroleid-nsg                      True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-control-plane-1b425d-hcpcontrolplaneoperatorroleid-vnet                     True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-file-csi-driver-1b425d-filestorageoperatorroleid-nsg                        True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-file-csi-driver-1b425d-filestorageoperatorroleid-subnet                     True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-ingress-1b425d-ingressoperatorroleid-subnet                                 True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-cp-kms-1b425d-keyvaultcryptouserroleid-keyvault                                True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-dp-file-csi-driver-1b425d-filestorageoperatorroleid-nsg                        True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-dp-file-csi-driver-1b425d-filestorageoperatorroleid-subnet                     True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-federatedcredentialsroleid-dpdiskcsidrivermi   True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-federatedcredentialsroleid-dpfilecsidrivermi   True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-federatedcredentialsroleid-dpimageregistrymi   True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-intsubnet      True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-nsg            True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-subnet         True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-hcpservicemanagedidentityroleid-vnet           True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-cloudcontrollermanagermi          True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-cloudnetworkconfigmi              True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-clusterapiazuremi                 True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-controlplanemi                    True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-diskcsidrivermi                   True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-filecsidrivermi                   True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-imageregistrymi                   True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-ingressmi                         True               Succeeded
capz-test-20260402-170951   mv1-mv1-tests-service-managed-identity-1b425d-readerroleid-kmsmi                             True               Succeeded
```

### 3. Delete the failed HcpOpenShiftCluster and let AROControlPlane recreate it

The failed cluster cannot be updated in-place. Delete it and the AROControlPlane
reconciler will recreate it:

```bash
$ oc delete -n capz-test-20260402-170951 hcpopenshiftclusters/mv1-tests
hcpopenshiftcluster.redhatopenshift.azure.com "mv1-tests" deleted
```

### 4. Verify the cluster is progressing

```bash
$ oc get hcpopenshiftclusters -A
NAMESPACE                   NAME        READY   SEVERITY   REASON        MESSAGE
capz-test-20260402-170951   mv1-tests   False   Info       Reconciling   The resource is in the process of being reconciled by the operator

$ az rest --url "/subscriptions/b23756f7-4594-40a3-980f-10bb6168fc20/resourceGroups/mv1-tests-resgroup/providers/Microsoft.RedHatOpenShift/hcpOpenShiftClusters/mv1-tests?api-version=2025-12-23-preview" \
  | grep provisioningState
    "provisioningState": "Accepted",
```

## Verifying the Fix

After the ARM-side fix is rolled out globally, repeat the same steps:

1. Deploy infrastructure **without** role assignments
2. Create the `HcpOpenShiftCluster`
3. Wait ~10 minutes - the cluster should **not** move to error state
4. Then assign the role assignments
5. The cluster should eventually reach `provisioningState: Succeeded`

The fix should allow the cluster to remain in a non-terminal state (e.g. `Accepted`
or `Provisioning`) while waiting for role assignments to propagate, instead of
immediately failing.
