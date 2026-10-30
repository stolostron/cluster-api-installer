# Migration Guide: ARO HCP API v20260901preview to v20261001

This guide covers moving ARO HCP resources from the ASO Kubernetes API version
`v20260901preview` to `v20261001`. The new version maps to the stable
`2026-10-01` Azure Resource Manager API.

## Prerequisites

The target CAPZ and ASO releases must serve `v20261001` for all three ARO HCP
resource kinds: `HcpOpenShiftCluster`, `HcpOpenShiftClustersNodePool`, and
`HcpOpenShiftClustersExternalAuth`. Do not install them until the pre-upgrade
gate below passes. When using `cluster-api-operator`, update the
`InfrastructureProvider` resource and ensure ASO's CRD pattern includes
`redhatopenshift.azure.com/*`; see
[infrastructure-provider-azure.yaml](../cluster-api-operator/infrastructure-provider-azure.yaml).

Before upgrading from `v20260901preview`, complete the pre-upgrade gate below
while the current ASO release can still read all versions recorded by the HCP
CRDs. If an HCP object or CRD still records the 2025 API version, migrate it
first using a transitional release that serves both the old version and
`v20260901preview`. Do not upgrade to a release that removes the 2025 API until
the pre-upgrade checks pass.

## Pre-upgrade gate: normalize to v20260901preview

Run these checks against the current cluster, before installing the release
that upgrades ASO/CAPZ to `v20261001`. The expected source state is:

- Every HCP object's `spec.originalVersion` is `v20260901preview`.
- Each HCP CRD's `status.storedVersions` contains only
  `v20260901previewstorage`.
- CAPZ's embedded HCP resources use
  `redhatopenshift.azure.com/v20260901preview`.

The CRD status uses the storage-version name, including the `storage` suffix;
it is not the public API version string.

Check the object `spec.originalVersion` values for all clusters, node pools, and
external-auth resources:

```bash
for resource in \
  hcpopenshiftclusters \
  hcpopenshiftclustersnodepools \
  hcpopenshiftclustersexternalauths; do
  kubectl get "${resource}.v20260901previewstorage.redhatopenshift.azure.com" \
    -A -o json |
    jq -r --arg resource "$resource" '
      .items[] |
      select(.spec.originalVersion != "v20260901preview") |
      [$resource, .metadata.namespace, .metadata.name,
       (.spec.originalVersion // "<unset>")] | @tsv'
done
```

This command must print no rows. If it finds an object still on
`v1api20251223preview`, first update its owning CAPZ `spec.resources[]` entry
to `redhatopenshift.azure.com/v20260901preview`, then write the child through
the served `v20260901preview` endpoint. If the parent reconciliation did not
perform that write, a same-value patch to `spec.azureName` triggers conversion
through the desired API version. Use the object's actual `spec.azureName`:

```bash
resource=hcpopenshiftclusters # or hcpopenshiftclustersnodepools / hcpopenshiftclustersexternalauths
namespace="REPLACE_WITH_NAMESPACE"
name="REPLACE_WITH_NAME"
azure_name="REPLACE_WITH_CURRENT_SPEC_AZURENAME"

kubectl patch "${resource}.v20260901preview.redhatopenshift.azure.com" \
  -n "$namespace" "$name" --type=json \
  -p="[{\"op\":\"test\",\"path\":\"/spec/azureName\",\"value\":\"${azure_name}\"},{\"op\":\"replace\",\"path\":\"/spec/azureName\",\"value\":\"${azure_name}\"}]"
```

This is a Kubernetes write and can trigger normal ASO reconciliation. Check
the object's reconcile policy and review the intended Azure effect before
applying it. For legacy SWIFT clusters without a VNet integration subnet, use
the documented compatibility/read-and-delete procedure; do not send a
fabricated subnet reference in an ARM PUT.

Check the active storage version and `status.storedVersions` on all three CRDs:

```bash
for crd in \
  hcpopenshiftclusters.redhatopenshift.azure.com \
  hcpopenshiftclustersnodepools.redhatopenshift.azure.com \
  hcpopenshiftclustersexternalauths.redhatopenshift.azure.com; do
  kubectl get crd "$crd" -o json | jq -r '
    .metadata.name as $name |
    [$name,
     ([.spec.versions[] | select(.storage) | .name] | join(",")),
     (.status.storedVersions | join(","))] | @tsv'
done
```

For each CRD, the storage version and the sole `status.storedVersions` entry
must both be `v20260901previewstorage`. If
`v1api20251223previewstorage` remains in `status.storedVersions`, let the
current ASO release's storage-version migration finish before upgrading. With
ASO CRD management in `auto` mode, ASO's migration controller rewrites objects
from deprecated storage versions and updates the CRD status. If CRD management
is configured differently, use the storage-migration procedure supported by
that ASO release. Do not manually remove an entry from `status.storedVersions`
as a substitute for rewriting stored objects.

Only proceed with the upgrade after all three checks pass: the object
`spec.originalVersion` inventory is empty, every CRD reports only
`v20260901previewstorage`, and CAPZ's embedded HCP resources declare
`v20260901preview`. This is the gate that ensures the 2025 API can be removed
without leaving HCP resources that depend on it.

## API version

After the pre-upgrade gate passes and the new CRDs are installed, change the
`apiVersion` of every ARO HCP resource, including clusters, node pools, and
external-auth resources:

```yaml
# Before
apiVersion: redhatopenshift.azure.com/v20260901preview

# After
apiVersion: redhatopenshift.azure.com/v20261001
```

The CAPZ ARO manifest generator now defaults to `v20261001`. To set it
explicitly, run it with `ARO_HCP_VERSION=v20261001`.

Update every embedded HCP resource's `apiVersion` in the owning CAPZ
`AROCluster`, `AROControlPlane`, and `AROMachinePool` resources, then apply the
updated CAPZ resources. Also update separately maintained HCP manifests. This
keeps CAPZ's desired resource definitions aligned with the new API.

Write each live HCP child through the served `v20261001` endpoint so ASO's
conversion webhook records `v20261001` in `spec.originalVersion`. If parent
reconciliation does not perform that write, use the same-value `spec.azureName`
patch shown above with the `v20261001` endpoint.

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

## Verify the v20261001 migration

After updating all CAPZ and standalone HCP resources, verify that no object
retains an earlier `spec.originalVersion`:

```bash
for resource in \
  hcpopenshiftclusters \
  hcpopenshiftclustersnodepools \
  hcpopenshiftclustersexternalauths; do
  kubectl get "${resource}.v20261001storage.redhatopenshift.azure.com" \
    -A -o json |
    jq -r --arg resource "$resource" '
      .items[] |
      select(.spec.originalVersion != "v20261001") |
      [$resource, .metadata.namespace, .metadata.name,
       (.spec.originalVersion // "<unset>")] | @tsv'
done
```

The command should print no rows. Then wait for ASO's CRD storage-version
migration to finish and inspect the CRDs again:

```bash
kubectl get crd \
  hcpopenshiftclusters.redhatopenshift.azure.com \
  hcpopenshiftclustersnodepools.redhatopenshift.azure.com \
  hcpopenshiftclustersexternalauths.redhatopenshift.azure.com \
  -o json | jq -r '.items[] |
    [.metadata.name,
     ([.spec.versions[] | select(.storage) | .name] | join(",")),
     (.status.storedVersions | join(","))] | @tsv'
```

The active storage version and the sole `status.storedVersions` entry should
both be `v20261001storage`. If `v20260901previewstorage` remains, wait for or
complete the ASO storage migration before removing that version from the CRD.
Do not patch `status.storedVersions` just to make the older version disappear.

## Apply the migration

Apply manifests after the new CRDs are installed. Keep the existing `spec`
unless you want to configure one of the new optional fields. Then check the ASO
resource conditions and the corresponding CAPI cluster status to confirm
reconciliation completed.

```diff
- apiVersion: redhatopenshift.azure.com/v20260901preview
+ apiVersion: redhatopenshift.azure.com/v20261001
  kind: HcpOpenShiftCluster
```
