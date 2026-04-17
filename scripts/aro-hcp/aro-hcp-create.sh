#!/bin/bash


# az cli
SUBSCRIPTIONID=$(az account show --query id --output tsv)

# ocm.token
OCM_PARAM="--use-auth-code"
if [ -f ocm.token ] ; then
    OCM_PARAM="--token=$(cat ocm.token)"
fi
ocm login --url=http://localhost:8000 "$OCM_PARAM"

if [ "$(ocm get /api/aro_hcp/v1alpha1/clusters |jq -r .kind)" != "ClusterList" ] ; then
    ARO_HCP_DIR=/home/mveber/projekty/capi/ARO-HCP
    KUBECONFIG=$(cd "$ARO_HCP_DIR";DEPLOY_ENV=dev make infra.svc.aks.kubeconfigfile) oc port-forward svc/clusters-service 8000:8000 -n cluster-service &

    N=10
    while [ "$(ocm get /api/aro_hcp/v1alpha1/clusters 2>/dev/null|jq -r .kind)" != "ClusterList" ] ; do
        N=$(( N - 1 ))
        if [ "$N" -le 0 ] ; then
            echo " CAN NOT LOGIN"
            exit 1
        fi
        echo -n .
        sleep 2
    done
    echo OK
fi

# sp.json
RESOURCENAME=$(jq      -r .displayName       sp.json)
TENANTID=$(jq          -r .tenant            sp.json)

# infra-names.js (created by aro-prepare-infra.sh)
CS_CLUSTER_NAME=$(jq   -r .CS_CLUSTER_NAME   infra-names.js)
RESOURCEGROUPNAME=$(jq -r .RESOURCEGROUPNAME infra-names.js)
VNET=$(jq              -r .VNET              infra-names.js)
SUBNET=$(jq            -r .SUBNET            infra-names.js)
REGION=$(jq            -r .REGION            infra-names.js)
USER=$(jq              -r .USER              infra-names.js)
NSG=$(jq               -r .NSG               infra-names.js)
OPERATORS_UAMIS_SUFFIX=$(jq -r .OPERATORS_UAMIS_SUFFIX infra-names.js)

MANAGEDRGNAME="$USER-$CS_CLUSTER_NAME-managed-rg"
NSG_ID="/subscriptions/$SUBSCRIPTIONID/resourceGroups/$RESOURCEGROUPNAME/providers/Microsoft.Network/networkSecurityGroups/$NSG"
SUBNETRESOURCEID="/subscriptions/$SUBSCRIPTIONID/resourceGroups/$RESOURCEGROUPNAME/providers/Microsoft.Network/virtualNetworks/$VNET/subnets/$SUBNET"
CP_CONTROL_PLANE_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-control-plane-$OPERATORS_UAMIS_SUFFIX"
CP_CAPZ_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-cluster-api-azure-$OPERATORS_UAMIS_SUFFIX"
CP_CCM_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-cloud-controller-manager-$OPERATORS_UAMIS_SUFFIX"
CP_INGRESS_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-ingress-$OPERATORS_UAMIS_SUFFIX"
CP_DISK_CSI_DRIVER_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-disk-csi-driver-$OPERATORS_UAMIS_SUFFIX"
CP_FILE_CSI_DRIVER_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-file-csi-driver-$OPERATORS_UAMIS_SUFFIX"
CP_IMAGE_REGISTRY_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-image-registry-$OPERATORS_UAMIS_SUFFIX"
CP_CNC_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-cloud-network-config-$OPERATORS_UAMIS_SUFFIX"
CP_KMS_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-cp-kms-$OPERATORS_UAMIS_SUFFIX"
DP_DISK_CSI_DRIVER_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-dp-disk-csi-driver-$OPERATORS_UAMIS_SUFFIX"
DP_IMAGE_REGISTRY_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-dp-image-registry-$OPERATORS_UAMIS_SUFFIX"
DP_FILE_CSI_DRIVER_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-dp-file-csi-driver-$OPERATORS_UAMIS_SUFFIX"
SERVICE_MANAGED_IDENTITY_UAMI="/subscriptions/$SUBSCRIPTIONID/resourcegroups/$RESOURCEGROUPNAME/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$USER-$CS_CLUSTER_NAME-service-managed-identity-$OPERATORS_UAMIS_SUFFIX"
cat <<EOF > cluster-test.json
{
  "name": "$CS_CLUSTER_NAME",
  "product": {
    "id": "aro"
  },
  "ccs": {
    "enabled": true
  },
  "region": {
    "id": "$REGION"
  },
  "hypershift": {
    "enabled": true
  },
  "multi_az": true,
  "azure": {
    "resource_name": "$RESOURCENAME",
    "subscription_id": "$SUBSCRIPTIONID",
    "resource_group_name": "$RESOURCEGROUPNAME",
    "tenant_id": "$TENANTID",
    "managed_resource_group_name": "$MANAGEDRGNAME",
    "subnet_resource_id": "$SUBNETRESOURCEID",
    "network_security_group_resource_id":"$NSG_ID",
    "operators_authentication": {
      "managed_identities": {
        "managed_identities_data_plane_identity_url": "https://dummyhost.identity.azure.net",
        "control_plane_operators_managed_identities": {
          "control-plane": {
            "resource_id": "$CP_CONTROL_PLANE_UAMI"
          },
          "cluster-api-azure": {
            "resource_id": "$CP_CAPZ_UAMI"
          },
          "cloud-controller-manager": {
            "resource_id": "$CP_CCM_UAMI"
          },
          "ingress": {
            "resource_id": "$CP_INGRESS_UAMI"
          },
          "disk-csi-driver": {
            "resource_id": "$CP_DISK_CSI_DRIVER_UAMI"
          },
          "file-csi-driver": {
            "resource_id": "$CP_FILE_CSI_DRIVER_UAMI"
          },
          "image-registry": {
            "resource_id": "$CP_IMAGE_REGISTRY_UAMI"
          },
          "cloud-network-config": {
            "resource_id": "$CP_CNC_UAMI"
          },
          "kms": {
            "resource_id": "$CP_KMS_UAMI"
          }
        },
        "data_plane_operators_managed_identities": {
          "disk-csi-driver": {
            "resource_id": "$DP_DISK_CSI_DRIVER_UAMI"
          },
          "image-registry": {
            "resource_id": "$DP_IMAGE_REGISTRY_UAMI"
          },
          "file-csi-driver": {
            "resource_id": "$DP_FILE_CSI_DRIVER_UAMI"
          }
        },
        "service_managed_identity": {
          "resource_id": "$SERVICE_MANAGED_IDENTITY_UAMI"
        }
      }
    }
  }
}
EOF

cat cluster-test.json | ocm post /api/aro_hcp/v1alpha1/clusters
