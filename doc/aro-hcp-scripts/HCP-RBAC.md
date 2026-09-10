# ARO HCP operator identity RBAC

The ARO HCP service validates the Azure permissions of the control-plane and
data-plane operator managed identities before provisioning the cluster. The
network permissions must be assigned at the scopes below so that permissions
inherit to the workload subnet.

| Operator identity | Role definition | Required scopes |
| --- | --- | --- |
| Control-plane and data-plane file CSI driver | Azure Red Hat OpenShift File Storage Operator (`0d7aedc0-15fd-4a67-a412-efad370c947e`) | VNet and NSG |
| Control-plane and data-plane image registry | Azure Red Hat OpenShift Image Registry Operator (`8b32b316-c2f5-4ddf-b05b-83dacd2d08b5`) | Resource group and VNet |

Do not add a subnet-scoped assignment for these roles. A VNet-scoped
assignment inherits to its subnets, and the ARO HCP validation checks the VNet
permission directly. The image-registry identities must use the Image Registry
Operator role; the File Storage Operator role is not an equivalent substitute.

## Troubleshooting a failed deployment

Use the resource group recorded by `capi-tests` rather than deriving a name
from an old log line:

```bash
az group show --name "$RESOURCEGROUPNAME" \
  --query '{name:name, provisioningState:properties.provisioningState, createdBy:managedBy, createdAt:tags.createdAt}'

az role assignment list --scope "$VNET_ID" --all \
  --query "[].{role:roleDefinitionName, principal:principalId, scope:scope}" -o table

az resource show --ids "$HCP_CLUSTER_ID" \
  --api-version 2024-06-10-preview \
  --query '{state:properties.provisioningState, conditions:properties.status.conditions}'
```

When the permissions are missing, the HCP resource remains in `Provisioning`
and its `RequirementsValid` condition reports the denied action, identity, and
resource. Compare those identities with the role assignments in the resource
group and VNet scopes.

The validation was introduced by [ARO-HCP PR #6575](https://github.com/Azure/ARO-HCP/pull/6575).
