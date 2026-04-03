# Migration Guide: ARO HCP API v1api20240610preview to v1api20251223preview

This document describes the changes required to migrate ARO HCP cluster
configurations from API version `v1api20240610preview` to `v1api20251223preview`.

## Prerequisites

Update CAPZ and Azure Service Operator to versions that include the
`v1api20251223preview` CRDs. If you are using `cluster-api-operator`,
update the `InfrastructureProvider` resource:

```yaml
apiVersion: operator.cluster.x-k8s.io/v1alpha2
kind: InfrastructureProvider
metadata:
  name: azure
  namespace: capz-system
spec:
  version: <new-version>
  fetchConfig:
    url: https://github.com/stolostron/cluster-api-provider-azure/releases/download/<new-version>/infrastructure-components.yaml
  additionalDeployments:
    azureserviceoperator-controller-manager:
      deployment:
        containers:
        - name: manager
          imageUrl: <new-aso-image>
          args:
            --crd-pattern: authorization.azure.com/*;managedidentity.azure.com/*;network.azure.com/*;eventhub.azure.com/*;storage.azure.com/*;web.azure.com/*;insights.azure.com/*;keyvault.azure.com/*;redhatopenshift.azure.com/*
```

## HcpOpenShiftCluster Changes

### 1. API Version

Update the `apiVersion` field on all ARO HCP resources:

```yaml
# Before
apiVersion: redhatopenshift.azure.com/v1api20240610preview

# After
apiVersion: redhatopenshift.azure.com/v1api20251223preview
```

This applies to `HcpOpenShiftCluster`, `HcpOpenShiftClustersNodePool`,
and `HcpOpenShiftClustersExternalAuth` resources.

### 2. KMS Configuration (etcd encryption)

The `vaultName` field moved from `activeKey` up to the `kms` level.
A new required field `visibility` was added.

```yaml
# Before (v1api20240610preview)
properties:
  etcd:
    dataEncryption:
      keyManagementMode: CustomerManaged
      customerManaged:
        encryptionType: KMS
        kms:
          activeKey:
            vaultName: "my-keyvault"
            name: "etcd-data-kms-encryption-key"

# After (v1api20251223preview)
properties:
  etcd:
    dataEncryption:
      keyManagementMode: CustomerManaged
      customerManaged:
        encryptionType: KMS
        kms:
          vaultName: "my-keyvault"          # moved from activeKey to kms level
          visibility: Public                 # new required field (Public or Private)
          activeKey:
            name: "etcd-data-kms-encryption-key"
```

### 3. VNet Integration Subnet (new required field)

A new required field `vnetIntegrationSubnetReference` was added to the
`platform` section. This subnet enables direct private network connectivity
between the hosted control plane and cluster nodes. It must be dedicated
to ARO HCP and cannot be shared with the cluster subnet or node pool subnets.

The integration subnet requires:
- A **separate address prefix** from the cluster subnet (e.g. `10.100.77.0/24`)
- A **delegation** to `Microsoft.RedHatOpenShift/hcpOpenShiftClusters`
- **No NSG** associated (unlike the cluster subnet)

#### Integration subnet ASO resource

Create a dedicated `VirtualNetworksSubnet` with the delegation:

```yaml
- apiVersion: network.azure.com/v1api20201101
  kind: VirtualNetworksSubnet
  metadata:
    name: my-vnet-my-integration-subnet
    namespace: default
  spec:
    owner:
      name: my-vnet
    addressPrefix: 10.100.77.0/24
    azureName: my-integration-subnet
    delegations:
      - name: Microsoft.RedHatOpenShift.hcpOpenShiftClusters
        serviceName: Microsoft.RedHatOpenShift/hcpOpenShiftClusters
```

#### HcpOpenShiftCluster reference

```yaml
# Before (v1api20240610preview)
properties:
  platform:
    subnetReference:
      group: network.azure.com
      kind: VirtualNetworksSubnet
      name: "my-vnet-my-subnet"
    networkSecurityGroupReference:
      group: network.azure.com
      kind: NetworkSecurityGroup
      name: "my-nsg"
    managedResourceGroup: "my-managed-rg"
    outboundType: LoadBalancer

# After (v1api20251223preview)
properties:
  platform:
    subnetReference:
      group: network.azure.com
      kind: VirtualNetworksSubnet
      name: "my-vnet-my-subnet"
    vnetIntegrationSubnetReference:          # new required field
      group: network.azure.com
      kind: VirtualNetworksSubnet
      name: "my-vnet-my-integration-subnet"
    networkSecurityGroupReference:
      group: network.azure.com
      kind: NetworkSecurityGroup
      name: "my-nsg"
    managedResourceGroup: "my-managed-rg"
    outboundType: LoadBalancer
```

#### Role assignments for the integration subnet

The `service-managed-identity` needs `hcpServiceManagedIdentityRoleId` on the
integration subnet (same as on the cluster subnet):

```yaml
- apiVersion: authorization.azure.com/v1api20220401
  kind: RoleAssignment
  metadata:
    name: <user>-<cluster>-service-managed-identity-<suffix>-hcpservicemanagedidentityroleid-intsubnet
  spec:
    owner:
      name: my-vnet-my-integration-subnet
      group: network.azure.com
      kind: VirtualNetworksSubnet
    principalIdFromConfig:
      name: identity-map-<user>-<cluster>-service-managed-identity-<suffix>
      key: principalId
    principalType: ServicePrincipal
    roleDefinitionReference:
      # c0ff367d-66d8-445e-917c-583feb0ef0d4 represents 'hcpServiceManagedIdentityRoleId'
      armId: /subscriptions/<sub-id>/providers/Microsoft.Authorization/roleDefinitions/c0ff367d-66d8-445e-917c-583feb0ef0d4
```

### 4. Operators Authentication (now required)

The `operatorsAuthentication` field under `platform` was optional in
`v1api20240610preview` and is now **required** in `v1api20251223preview`.
If you were already providing it, no change is needed.

### 5. Image Digest Mirrors (new optional field)

A new optional field `imageDigestMirrors` allows pulling images from
mirrored registries using digest specifications:

```yaml
# v1api20251223preview only (optional)
properties:
  imageDigestMirrors:
    - source: "registry.example.com/my-repo"
      mirrors:
        - "mirror1.example.com/my-repo"
        - "mirror2.example.com/my-repo"
```

## HcpOpenShiftClustersNodePool Changes

### 1. OS Disk Type (new optional field)

A new optional field `diskType` was added to the `osDisk` section:

```yaml
properties:
  platform:
    osDisk:
      diskStorageAccountType: "Standard_LRS"
      diskType: Managed                      # new optional field (Ephemeral or Managed)
      sizeGiB: 128                           # minimum value is now 64
```

### 2. OS Disk Size Constraint

`sizeGiB` now has a minimum value of `64`. Ensure your configuration
uses a value of 64 or higher.

## HcpOpenShiftClustersExternalAuth Changes

No structural changes. Only minor documentation clarifications around the
`prefixPolicy` default behavior.

## Summary of Breaking Changes

| Change | Type | Action Required |
|--------|------|-----------------|
| KMS `vaultName` moved to `kms` level | Breaking | Move field, add `visibility` |
| `vnetIntegrationSubnetReference` added | Breaking | Add field with dedicated subnet |
| `operatorsAuthentication` now required | Breaking | Ensure field is present |
| `osDisk.sizeGiB` minimum 64 | Constraint | Verify value >= 64 |

## Example: Complete Before/After diff

```diff
  - apiVersion: redhatopenshift.azure.com/v1api20240610preview
+ - apiVersion: redhatopenshift.azure.com/v1api20251223preview
    kind: HcpOpenShiftCluster
    spec:
      properties:
        platform:
          subnetReference:
            group: network.azure.com
            kind: VirtualNetworksSubnet
            name: "my-vnet-my-subnet"
+         vnetIntegrationSubnetReference:
+           group: network.azure.com
+           kind: VirtualNetworksSubnet
+           name: "my-vnet-my-integration-subnet"
        etcd:
          dataEncryption:
            customerManaged:
              encryptionType: KMS
              kms:
+               vaultName: "my-keyvault"
+               visibility: Public
                activeKey:
-                 vaultName: "my-keyvault"
                  name: "etcd-data-kms-encryption-key"
```
