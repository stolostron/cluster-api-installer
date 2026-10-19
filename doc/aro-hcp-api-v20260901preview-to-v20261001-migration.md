# Migration Guide: ARO HCP API v20260901preview to v20261001

This guide covers moving ARO HCP resources from the ASO Kubernetes API version
`v20260901preview` to `v20261001`. The new version maps to the stable
`2026-10-01` Azure Resource Manager API.

## Prerequisites

Install CAPZ and ASO releases whose CRDs serve `v20261001` for all three ARO HCP
resource kinds: `HcpOpenShiftCluster`, `HcpOpenShiftClustersNodePool`, and
`HcpOpenShiftClustersExternalAuth`. When using `cluster-api-operator`, update
the `InfrastructureProvider` resource and ensure ASO's CRD pattern includes
`redhatopenshift.azure.com/*`; see
[infrastructure-provider-azure.yaml](../cluster-api-operator/infrastructure-provider-azure.yaml).

Apply the updated CRDs before applying manifests that use `v20261001`.

## API version

Change the `apiVersion` of every ARO HCP resource, including clusters, node
pools, and external-auth resources:

```yaml
# Before
apiVersion: redhatopenshift.azure.com/v20260901preview

# After
apiVersion: redhatopenshift.azure.com/v20261001
```

The CAPZ ARO manifest generator now defaults to `v20261001`. To set it
explicitly, run it with `ARO_HCP_VERSION=v20261001`.

## Schema changes

The `v20261001` CRDs do not introduce new required `spec` fields compared with
`v20260901preview`. Existing desired configuration can remain as-is. The
following optional cluster fields are available in the stable API.

### Key Vault type for customer-managed etcd encryption

`spec.properties.etcd.dataEncryption.customerManaged.kms.keyVaultType` selects
the key store type. Accepted values are `KeyVault` and `ManagedHSM`. If omitted,
the API defaults to `KeyVault`.

```yaml
properties:
  etcd:
    dataEncryption:
      customerManaged:
        kms:
          keyVaultType: ManagedHSM
```

### Container registry image pulls

`spec.properties.platform.containerRegistry.managedIdentityReference` can
reference a user-assigned managed identity for authenticating image pulls on
worker nodes. It is optional; existing clusters do not need this field unless
they use this configuration.

```yaml
properties:
  platform:
    containerRegistry:
      managedIdentityReference:
        group: managedidentity.azure.com
        kind: UserAssignedIdentity
        name: <managed-identity-resource-name>
```

### Status fields

The stable API adds observed status fields. Do not include them in desired
manifests:

- Clusters: `status.properties.status.activeVersions` and
  `status.properties.platform.containerRegistry.managedIdentity`.
- Node pools: `status.properties.status.activeVersions`.

These fields are populated by the service. The
`HcpOpenShiftClustersExternalAuth` schema has no desired-state field changes in
this API transition.

## Apply the migration

Update the API version in your manifests and apply them after the new CRDs are
installed. Keep the existing `spec` unless you want to configure one of the new
optional fields. Then check the ASO resource conditions and the corresponding
CAPI cluster status to confirm reconciliation completed.

```diff
- apiVersion: redhatopenshift.azure.com/v20260901preview
+ apiVersion: redhatopenshift.azure.com/v20261001
  kind: HcpOpenShiftCluster
```
