#!/bin/bash
OUT_FILE=$(dirname $0)/aro-template-new.yaml


cat <<EOF | cat > $OUT_FILE
# Equivalent to:
# az group create --name "\${RESOURCEGROUPNAME}" --location "\${REGION}"
# This YAML creates a Resource Group named "\${RESOURCEGROUPNAME}" in the specified Azure region "\${REGION}".
apiVersion: resources.azure.com/v1api20200601
kind: ResourceGroup
metadata:
  name: \${RESOURCEGROUPNAME}
  namespace: default
spec:
  location: \${REGION}
---
# Equivalent to:
# az network vnet create -n "\${VNET}" -g "\${RESOURCEGROUPNAME}"
# This YAML creates a virtual network named "\${VNET}" in the "\${RESOURCEGROUPNAME}" resource group.
apiVersion: network.azure.com/v1api20201101
kind: VirtualNetwork
metadata:
  name: \${VNET}
  namespace: default
spec:
  location: \${REGION}
  owner:
    name: \${RESOURCEGROUPNAME}
  addressSpace:
    addressPrefixes:
      - 10.100.0.0/15
---
# Equivalent to:
# az network nsg create -n "\${NSG}" -g "\${RESOURCEGROUPNAME}"
# This YAML creates a Network Security Group (NSG) named "\${NSG}" in the "\${RESOURCEGROUPNAME}" resource group.
apiVersion: network.azure.com/v1api20201101
kind: NetworkSecurityGroup
metadata:
  name: \${NSG}
  namespace: default
spec:
  location: \${REGION}
  owner:
    name: \${RESOURCEGROUPNAME}
---
# Equivalent to:
# az network vnet subnet create -n "\${SUBNET}" -g "\${RESOURCEGROUPNAME}" --vnet-name "\${VNET}" --network-security-group "\${NSG}"
# This YAML creates a subnet named "\${SUBNET}" in the "\${VNET}" virtual network and associates it with the "\${NSG}" Network Security Group.
apiVersion: network.azure.com/v1api20201101
kind: VirtualNetworksSubnet
metadata:
  name: \${VNET}-\${SUBNET}
  namespace: default
spec:
  owner:
    name: \${VNET}
  addressPrefix: 10.100.76.0/24
  azureName: \${SUBNET}
  networkSecurityGroup:
    reference:
      name: \${NSG}
      group: network.azure.com
      kind: NetworkSecurityGroup
---
# Equivalent to:
# az keyvault create --name "\$KV" -g \${RESOURCEGROUPNAME} --location "\${REGION}" --enable-rbac-authorization true
# This YAML creates a key vault named "\${KV}" in the "\${RESOURCEGROUPNAME}" resource group.
apiVersion: keyvault.azure.com/v1api20230701
kind: Vault
metadata:
  name: "\${KV}"
  namespace: default
spec:
  location: "\${REGION}"
  owner:
    name: "\${RESOURCEGROUPNAME}"
  properties:
    createMode: createOrRecover
    enableRbacAuthorization: true
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    enableSoftDelete: true
    tenantId: "\${AZURE_TENANT_ID}"
    accessPolicies: [] 
    sku:
      family: A
      name: standard
EOF

for IDENTITY_NAME in \
    \${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-cluster-api-azure-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-ingress-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-disk-csi-driver-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-image-registry-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-cp-kms-\${OPERATORS_UAMIS_SUFFIX} \
    \
    \${USER}-\${CS_CLUSTER_NAME}-dp-disk-csi-driver-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-dp-image-registry-\${OPERATORS_UAMIS_SUFFIX} \
    \${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX} \
    \
    \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX} \
; do
cat >> $OUT_FILE <<EOF
---
# Equivalent to:
# az identity create -n "$IDENTITY_NAME" -g "\${RESOURCEGROUPNAME}"
# This YAML creates a managed identity named "$IDENTITY_NAME" in the "\${RESOURCEGROUPNAME}" resource group.
apiVersion: managedidentity.azure.com/v1api20230131
kind: UserAssignedIdentity
metadata:
  name: $IDENTITY_NAME
  namespace: default
spec:
  location: \${REGION}
  owner:
    name: \${RESOURCEGROUPNAME}
  operatorSpec:
    configMaps:
      principalId:
        name: identity-map-$IDENTITY_NAME
        key: principalId
      clientId:
        name: identity-map-$IDENTITY_NAME
        key: clientId
EOF
done

cat >> $OUT_FILE <<EOF
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-cluster-api-azure-\${OPERATORS_UAMIS_SUFFIX}-hcpclusterapiproviderroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-cluster-api-azure-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 88366f10-ed47-4cc0-9fab-c8a06148393e represents 'hcpClusterApiProviderRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/88366f10-ed47-4cc0-9fab-c8a06148393e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-clusterapiazuremi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-cluster-api-azure-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-kms-\${OPERATORS_UAMIS_SUFFIX}-keyvaultcryptouserroleid-keyvault
  namespace: default
spec:
  owner:
    name: \${KV}
    group: keyvault.azure.com
    kind: Vault
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-kms-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 12338af0-0e69-4776-bea7-57ae8d297424 represents 'keyVaultCryptoUserRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/12338af0-0e69-4776-bea7-57ae8d297424
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-kmsmi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-kms-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX}-hcpcontrolplaneoperatorroleid-vnet
  namespace: default
spec:
  owner:
    name: \${VNET}
    group: network.azure.com
    kind: VirtualNetwork
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # fc0c873f-45e9-4d0d-a7d1-585aab30c6ed represents 'hcpControlPlaneOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/fc0c873f-45e9-4d0d-a7d1-585aab30c6ed
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX}-hcpcontrolplaneoperatorroleid-nsg
  namespace: default
spec:
  owner:
    name: \${NSG}
    group: network.azure.com
    kind: NetworkSecurityGroup
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # fc0c873f-45e9-4d0d-a7d1-585aab30c6ed represents 'hcpControlPlaneOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/fc0c873f-45e9-4d0d-a7d1-585aab30c6ed
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-controlplanemi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX}-cloudcontrollermanagerroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # a1f96423-95ce-4224-ab27-4e3dc72facd4 represents 'cloudControllerManagerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX}-cloudcontrollermanagerroleid-nsg
  namespace: default
spec:
  owner:
    name: \${NSG}
    group: network.azure.com
    kind: NetworkSecurityGroup
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # a1f96423-95ce-4224-ab27-4e3dc72facd4 represents 'cloudControllerManagerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/a1f96423-95ce-4224-ab27-4e3dc72facd4
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-cloudcontrollermanagermi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-ingress-\${OPERATORS_UAMIS_SUFFIX}-ingressoperatorroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-ingress-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 0336e1d3-7a87-462b-b6db-342b63f7802c represents 'ingressOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0336e1d3-7a87-462b-b6db-342b63f7802c
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-ingressmi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-ingress-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-diskcsidrivermi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-disk-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}-filestorageoperatorroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 0d7aedc0-15fd-4a67-a412-efad370c947e represents 'fileStorageOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}-filestorageoperatorroleid-nsg
  namespace: default
spec:
  owner:
    name: \${NSG}
    group: network.azure.com
    kind: NetworkSecurityGroup
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 0d7aedc0-15fd-4a67-a412-efad370c947e represents 'fileStorageOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-filecsidrivermi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-imageregistrymi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-image-registry-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX}-networkoperatorroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # be7a6435-15ae-4171-8f30-4a343eff9e8f represents 'networkOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/be7a6435-15ae-4171-8f30-4a343eff9e8f
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX}-networkoperatorroleid-vnet
  namespace: default
spec:
  owner:
    name: \${VNET}
    group: network.azure.com
    kind: VirtualNetwork
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # be7a6435-15ae-4171-8f30-4a343eff9e8f represents 'networkOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/be7a6435-15ae-4171-8f30-4a343eff9e8f
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-readerroleid-cloudnetworkconfigmi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # acdd72a7-3385-48ef-bd42-f606fba81ae7 represents 'readerRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-federatedcredentialsroleid-dpdiskcsidrivermi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-dp-disk-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # ef318e2a-8334-4a05-9e4a-295a196c6a6e represents 'federatedCredentialsRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-federatedcredentialsroleid-dpfilecsidrivermi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # ef318e2a-8334-4a05-9e4a-295a196c6a6e represents 'federatedCredentialsRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}-filestorageoperatorroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 0d7aedc0-15fd-4a67-a412-efad370c947e represents 'fileStorageOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}-filestorageoperatorroleid-nsg
  namespace: default
spec:
  owner:
    name: \${NSG}
    group: network.azure.com
    kind: NetworkSecurityGroup
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # 0d7aedc0-15fd-4a67-a412-efad370c947e represents 'fileStorageOperatorRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/0d7aedc0-15fd-4a67-a412-efad370c947e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-federatedcredentialsroleid-dpimageregistrymi
  namespace: default
spec:
  owner:
    name: \${USER}-\${CS_CLUSTER_NAME}-dp-image-registry-\${OPERATORS_UAMIS_SUFFIX}
    group: managedidentity.azure.com
    kind: UserAssignedIdentity
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # ef318e2a-8334-4a05-9e4a-295a196c6a6e represents 'federatedCredentialsRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/ef318e2a-8334-4a05-9e4a-295a196c6a6e
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-hcpservicemanagedidentityroleid-vnet
  namespace: default
spec:
  owner:
    name: \${VNET}
    group: network.azure.com
    kind: VirtualNetwork
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # c0ff367d-66d8-445e-917c-583feb0ef0d4 represents 'hcpServiceManagedIdentityRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/c0ff367d-66d8-445e-917c-583feb0ef0d4
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-hcpservicemanagedidentityroleid-subnet
  namespace: default
spec:
  owner:
    name: \${VNET}-\${SUBNET}
    group: network.azure.com
    kind: VirtualNetworksSubnet
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # c0ff367d-66d8-445e-917c-583feb0ef0d4 represents 'hcpServiceManagedIdentityRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/c0ff367d-66d8-445e-917c-583feb0ef0d4
---
apiVersion: authorization.azure.com/v1api20220401
kind: RoleAssignment
metadata:
  name: \${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}-hcpservicemanagedidentityroleid-nsg
  namespace: default
spec:
  owner:
    name: \${NSG}
    group: network.azure.com
    kind: NetworkSecurityGroup
  principalIdFromConfig:
    name: identity-map-\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}
    key: principalId
  principalType: ServicePrincipal
  roleDefinitionReference:
    # c0ff367d-66d8-445e-917c-583feb0ef0d4 represents 'hcpServiceManagedIdentityRoleId'
    armId: /subscriptions/\${AZURE_SUBSCRIPTION_ID}/providers/Microsoft.Authorization/roleDefinitions/c0ff367d-66d8-445e-917c-583feb0ef0d4
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: AROControlPlane
metadata:
 name: \${CS_CLUSTER_NAME}-control-plane
 namespace: default
spec:
 aroClusterName: \${CS_CLUSTER_NAME}
 platform:
   location: \${REGION}
   resourceGroup: \${RESOURCEGROUPNAME}
   subnet: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourceGroups/\${RESOURCEGROUPNAME}/providers/Microsoft.Network/virtualNetworks/\${VNET}/subnets/\${SUBNET}"
   keyVault: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourceGroups/\${RESOURCEGROUPNAME}/providers/Microsoft.KeyVault/vaults/\${KV}"
   outboundType: LoadBalancer
   networkSecurityGroupId: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourceGroups/\${RESOURCEGROUPNAME}/providers/Microsoft.Network/networkSecurityGroups/\${NSG}"
   managedIdentities:
     controlPlaneOperators:
       cloudControllerManager: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-cloud-controller-manager-\${OPERATORS_UAMIS_SUFFIX}"
       cloudNetworkConfigManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-cloud-network-config-\${OPERATORS_UAMIS_SUFFIX}"
       clusterApiAzureManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-cluster-api-azure-\${OPERATORS_UAMIS_SUFFIX}"
       controlPlaneOperatorsManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-control-plane-\${OPERATORS_UAMIS_SUFFIX}"
       diskCsiDriverManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-disk-csi-driver-\${OPERATORS_UAMIS_SUFFIX}"
       fileCsiDriverManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}"
       imageRegistryManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-image-registry-\${OPERATORS_UAMIS_SUFFIX}"
       ingressManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-ingress-\${OPERATORS_UAMIS_SUFFIX}"
       kmsManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-cp-kms-\${OPERATORS_UAMIS_SUFFIX}"
     dataPlaneOperators:
       diskCsiDriverManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-dp-disk-csi-driver-\${OPERATORS_UAMIS_SUFFIX}"
       fileCsiDriverManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-dp-file-csi-driver-\${OPERATORS_UAMIS_SUFFIX}"
       imageRegistryManagedIdentities: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-dp-image-registry-\${OPERATORS_UAMIS_SUFFIX}"
     serviceManagedIdentity: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourcegroups/\${RESOURCEGROUPNAME}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/\${USER}-\${CS_CLUSTER_NAME}-service-managed-identity-\${OPERATORS_UAMIS_SUFFIX}"
 visibility: Public
 network:
   machineCIDR: "10.0.0.0/16"
   podCIDR: "10.128.0.0/14"
   serviceCIDR: "172.30.0.0/16"
   hostPrefix: 23
   networkType: OVNKubernetes
 domainPrefix: \${CS_CLUSTER_NAME}
 version: "\${OCP_VERSION}"
 channelGroup: stable
 versionGate: WaitForAcknowledge
 subscriptionID: "\${AZURE_SUBSCRIPTION_ID}"
 identityRef:
    kind: AzureClusterIdentity
    name: \${AZURE_CLUSTER_IDENTITY_NAME}
    namespace: \${AZURE_CLUSTER_IDENTITY_NAMESPACE}
 additionalTags:
   environment: production
   owner: sre-team
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AROMachinePool
metadata:
 name: \${CS_CLUSTER_NAME}-mp-0
 namespace: default
spec:
  nodePoolName: w-\${REGION}-mp-0
  version: "\${OCP_VERSION_MP}"
  platform:
    subnet: "/subscriptions/\${AZURE_SUBSCRIPTION_ID}/resourceGroups/\${RESOURCEGROUPNAME}/providers/Microsoft.Network/virtualNetworks/\${VNET}/subnets/\${SUBNET}"
    vmSize: "Standard_D4s_v3"
    diskSizeGiB: 128
    diskStorageAccountType: "Premium_LRS"
  labels:
     region: \${REGION}
  # taints:
  #   - key: "example.com/special"
  #     value: "true"
  #     effect: "NoSchedule"
  additionalTags:
    environment: production
    cost-center: engineering
  autoRepair: true
  autoscaling:
    minReplicas: 2
    maxReplicas: 4
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: MachinePool
metadata:
  name: \${CS_CLUSTER_NAME}-mp-0
  namespace: default
  labels:
    cluster.x-k8s.io/cluster-name: \${CS_CLUSTER_NAME}
spec:
  replicas: 2
  clusterName: \${CS_CLUSTER_NAME}
  template:
    spec:
      bootstrap:
        dataSecretName: \${CS_CLUSTER_NAME}-kubeconfig
#        configRef:
#           apiVersion: bootstrap.cluster.x-k8s.io/v1beta1
#           kind: KubeadmConfig
#           name: \${CS_CLUSTER_NAME}-mp-0
#           namespace: default
      clusterName: \${CS_CLUSTER_NAME}
      infrastructureRef:
        apiGroup: infrastructure.cluster.x-k8s.io
        kind: AROMachinePool
        name: \${CS_CLUSTER_NAME}-mp-0
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AROCluster
metadata:
 name: \${CS_CLUSTER_NAME}
 namespace: default
 labels:
   cluster.x-k8s.io/cluster-name: \${CS_CLUSTER_NAME}
spec:
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: \${CS_CLUSTER_NAME}
  namespace: default
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 192.168.0.0/16
  controlPlaneRef:
    apiGroup: controlplane.cluster.x-k8s.io
    kind: AROControlPlane
    name: \${CS_CLUSTER_NAME}-control-plane
  infrastructureRef:
    apiGroup: infrastructure.cluster.x-k8s.io
    kind: AROCluster
    name: \${CS_CLUSTER_NAME}
---
EOF
