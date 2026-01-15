#!/bin/bash

HOST_PORT=${HOST_PORT:-localhost:8443}

# az cli
SUBSCRIPTIONID=$(az account show --query id --output tsv)

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
OCP_VERSION=$(jq       -r .OCP_VERSION       infra-names.js)
OPERATORS_UAMIS_SUFFIX=$(jq -r .OPERATORS_UAMIS_SUFFIX infra-names.js)

arm_system_data_header() {                                                                                                                                                                                                                   
    echo "X-Ms-Arm-Resource-System-Data: {\"createdBy\": \"${USER}\", \"createdByType\": \"User\", \"createdAt\": \"$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")\"}"
}

correlation_headers() {
    local HEADERS=( )
    if [ -n "$(which uuidgen 2> /dev/null)" ]; then
        HEADERS+=( "X-Ms-Correlation-Request-Id: $(uuidgen)" )
        HEADERS+=( "X-Ms-Client-Request-Id: $(uuidgen)" )
        HEADERS+=( "X-Ms-Return-Client-Request-Id: true" )
    fi
    printf '%s\n' "${HEADERS[@]}"
}

arm_x_ms_identity_url_header() {
  # Requests directly against the frontend
  # need to send a X-Ms-Identity-Url HTTP
  # header, which simulates what ARM performs.
  # By default we set a dummy value, which is
  # enough in the environments where a real
  # Managed Identities Data Plane does not
  # exist like in the development or integration
  # environments. The default can be overwritten
  # by providing the environment variable
  # ARM_X_MS_IDENTITY_URL when running the script.
  : ${ARM_X_MS_IDENTITY_URL:="https://dummyhost.identity.azure.net"}
  echo "X-Ms-Identity-Url: ${ARM_X_MS_IDENTITY_URL}"
}

test_api_available() {
(arm_system_data_header; correlation_headers; arm_x_ms_identity_url_header) | curl -sSi -X PUT "${HOST_PORT}/subscriptions/${SUBSCRIPTIONID}/resourceGroups/some-non-existing-rg/providers/Microsoft.RedHatOpenshift/hcpOpenShiftClusters?api-version=2024-06-10-preview" \
    --header @- > /dev/null 2>&1
   echo $?
}

if [ "$(test_api_available)" != "0" ] ; then
    ARO_HCP_DIR=ARO-HCP
    if [ ! -d "$ARO_HCP_DIR" ] ; then
        echo Clonning  ARO-HCP
        git clone https://github.com/Azure/ARO-HCP.git "$ARO_HCP_DIR"
    fi
    KUBECONFIG_AKS=$(cd "$ARO_HCP_DIR"; DEPLOY_ENV=dev make infra.svc.aks.kubeconfigfile)
    KUBECONFIG="$KUBECONFIG_AKS" oc port-forward -n aro-hcp svc/aro-hcp-frontend 8443:8443 &

    echo -n Checking API in ${HOST_PORT}
    sleep 2
    N=10
    while [ "$(test_api_available)" != "0" ] ; do
        N=$(( N - 1 ))
        if [ "$N" -le 0 ] ; then
            echo " CAN NOT ACCESS AZURE API"
            exit 1
        fi
        echo -n .
        sleep 2
    done
    echo OK
fi


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
cat <<EOF | json_pp > cluster-azure-new.json
{
  "properties": {
    "location": "${REGION}",
    "name": "${S_CLUSTER_NAME}",
    "version": {
      "id": "${OCP_VERSION}",
      "channelGroup": "stable"
    },
    "dns": {},
    "network": {
      "networkType": "OVNKubernetes",
      "podCidr": "10.128.0.0/14",
      "serviceCidr": "172.30.0.0/16",
      "machineCidr": "10.0.0.0/16",
      "hostPrefix": 23
    },
    "console": {},
    "api": {
      "visibility": "public"
    },
    "platform": {
      "managedResourceGroup": "$MANAGEDRGNAME",
      "subnetId": "$SUBNETRESOURCEID",
      "outboundType": "loadBalancer",
      "networkSecurityGroupId": "$NSG_ID",
      "operatorsAuthentication": {
        "userAssignedIdentities": {
          "controlPlaneOperators": {
            "cluster-api-azure": "$CP_CAPZ_UAMI",
            "control-plane": "$CP_CONTROL_PLANE_UAMI",
            "cloud-controller-manager": "$CP_CCM_UAMI",
            "ingress": "$CP_INGRESS_UAMI",
            "disk-csi-driver": "$CP_DISK_CSI_DRIVER_UAMI",
            "file-csi-driver": "$CP_FILE_CSI_DRIVER_UAMI",
            "image-registry": "$CP_IMAGE_REGISTRY_UAMI",
            "cloud-network-config": "$CP_CNC_UAMI",
            "kms": "$CP_KMS_UAMI"
          },
          "dataPlaneOperators": {
            "disk-csi-driver": "$DP_DISK_CSI_DRIVER_UAMI",
            "file-csi-driver": "$DP_FILE_CSI_DRIVER_UAMI",
            "image-registry": "$DP_IMAGE_REGISTRY_UAMI"
          },
          "serviceManagedIdentity": "$SERVICE_MANAGED_IDENTITY_UAMI"
        }
      }
    }
  },
  "identity": {
    "type": "UserAssigned",
    "userAssignedIdentities": {
      "$CP_CAPZ_UAMI": {},
      "$CP_CONTROL_PLANE_UAMI": {},
      "$CP_CCM_UAMI": {},
      "$CP_INGRESS_UAMI": {},
      "$CP_DISK_CSI_DRIVER_UAMI": {},
      "$CP_FILE_CSI_DRIVER_UAMI": {},
      "$CP_IMAGE_REGISTRY_UAMI": {},
      "$CP_CNC_UAMI": {},
      "$CP_KMS_UAMI": {},
      "$SERVICE_MANAGED_IDENTITY_UAMI": {}
    }
  }
}
EOF


echo PUT "${HOST_PORT}/subscriptions/${SUBSCRIPTIONID}/resourceGroups/${RESOURCEGROUPNAME}/providers/Microsoft.RedHatOpenshift/hcpOpenShiftClusters/${CS_CLUSTER_NAME}?api-version=2024-06-10-preview" 
(arm_system_data_header; correlation_headers; arm_x_ms_identity_url_header) | curl -sSi -X PUT "${HOST_PORT}/subscriptions/${SUBSCRIPTIONID}/resourceGroups/${RESOURCEGROUPNAME}/providers/Microsoft.RedHatOpenshift/hcpOpenShiftClusters/${CS_CLUSTER_NAME}?api-version=2024-06-10-preview" \
    --header @- \
    --json @cluster-azure.json

echo
