# Migration Guide: ARO HCP API v1api20251223preview to v20260901preview

This document describes the migration from the ARO HCP Kubernetes API
`v1api20251223preview` to `v20260901preview`. The latter is the API version
generated from the `2026-09-01-preview` Azure Resource Manager API.

## Prerequisites

Use CAPZ `v1.26.0-hcpclusters.1` and ASO `v2.18.0-hcpclusters.3`, or later
releases containing the `v20260901preview` CRDs. If you use
`cluster-api-operator`, update the `InfrastructureProvider` resource as shown
in [infrastructure-provider-azure.yaml](../cluster-api-operator/infrastructure-provider-azure.yaml).

The ASO deployment must include the ARO HCP CRDs:

```yaml
args:
  --crd-pattern: authorization.azure.com/*;managedidentity.azure.com/*;network.azure.com/*;eventhub.azure.com/*;storage.azure.com/*;web.azure.com/*;insights.azure.com/*;keyvault.azure.com/*;redhatopenshift.azure.com/*;containerservice.azure.com/*;resources.azure.com/*
```

## API version

Change every ARO HCP resource from the old Kubernetes API version to the new
one. This includes `HcpOpenShiftCluster`, `HcpOpenShiftClustersNodePool`, and
`HcpOpenShiftClustersExternalAuth`.

```yaml
# Before
apiVersion: redhatopenshift.azure.com/v1api20251223preview

# After
apiVersion: redhatopenshift.azure.com/v20260901preview
```

The ARM API version is `2026-09-01-preview` for both versions. The change is
also an API-prefix change: ASO versions introduced after v2.16 use `v` rather
than `v1api`. Do not change the resource kind or the `spec` structure solely
because of this API-version change.

## API schema changes

The following differences are present in the CRDs when comparing
`v1api20251223preview` with `v20260901preview`.

### HcpOpenShiftCluster

Two optional configuration fields were added under `spec.properties`:

```yaml
properties:
  cryptoRestrictions: None  # or FIPS
  ingress:
    type: Public             # Disabled, Private, or Public
```

The etcd encryption contract became stricter:

- `properties.etcd.dataEncryption.keyManagementMode` is now required.
- Its only accepted value is `CustomerManaged`; `PlatformManaged` is no
  longer accepted by the `v20260901preview` schema.

For example, an explicit customer-managed configuration is now required when
using the `dataEncryption` object:

```yaml
properties:
  etcd:
    dataEncryption:
      keyManagementMode: CustomerManaged
      customerManaged:
        encryptionType: KMS
        kms:
          vaultName: "my-keyvault"
          visibility: Public
          activeKey:
            name: "etcd-data-kms-encryption-key"
```

The previously introduced fields such as
`vnetIntegrationSubnetReference`, `operatorsAuthentication`,
`imageDigestMirrors`, and `osDisk.diskType` are unchanged by this API
transition. They are listed in the previous migration guide and are not
new changes in `v20260901preview`.

### HcpOpenShiftClustersNodePool

`platform.osDisk.sizeGiB` keeps its existing minimum of 64, and now also has a
maximum of 4095 for managed disks. Ephemeral disks may have a lower effective
Azure limit depending on the VM size and local cache capacity.

```yaml
properties:
  platform:
    osDisk:
      sizeGiB: 128  # 64 <= sizeGiB <= 4095 for managed disks
```

### HcpOpenShiftClustersExternalAuth

The ARM-backed status shape changed from a singular `condition` object to a
`status.conditions` array. Consumers reading status must use the new path:

```yaml
# Before
status:
  properties:
    condition:
      type: Available

# After
status:
  properties:
    status:
      conditions:
      - type: Available
```

The resource's desired `spec` fields are otherwise unchanged.

### Status schema

All three CRDs now expose the generated ARM resource status conditions under
`status.properties.status.conditions`. These are read-only fields populated by
the service; manifests should not set them. The condition entries contain
`lastTransitionTime`, `message`, `reason`, `status`, and `type`.

## Example

```diff
- apiVersion: redhatopenshift.azure.com/v1api20251223preview
+ apiVersion: redhatopenshift.azure.com/v20260901preview
  kind: HcpOpenShiftCluster
```

Apply the updated CRDs and provider configuration before applying manifests
that use `v20260901preview`. Existing objects can be migrated by updating the
API version in their manifests and applying them through the normal CAPI/ASO
reconciliation flow.
