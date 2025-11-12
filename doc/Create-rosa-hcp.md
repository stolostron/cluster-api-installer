# Creating a ROSA HCP cluster

## Prerequisites

1. Create an AWS access key following the AWS [doc](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)
   **Note:** Make sure the AWS ROSA managed [policies](https://docs.aws.amazon.com/rosa/latest/userguide/security-iam-awsmanpol.html) are attached to your AWS user permissions.

1. Create a service account by visiting [https://console.redhat.com/iam/service-accounts](https://console.redhat.com/iam/service-accounts). If you already have a service account, you can skip this step.

   For every newly created service account, activate the account using the [ROSA command line tool](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/cli_tools/rosa-cli). First, log in using your newly created service account
   ```shell
   rosa login --client-id ... --client-secret ...
   ```
   Then activate your service account
   ```shell
   rosa whoami
   ```
1. Install Redhat `oc` CLI following installation [doc](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/cli_tools/openshift-cli-oc)

1. Install Advanced Cluster Management (ACM) operator v2.15 on an existing OpenShift 4.16+ cluster, either through the [OperatorHub](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/install/installing#installing-from-the-operatorhub) or via the [CLI](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.15/html/install/installing#installing-from-the-cli).

## Enable CAPI, CAPA and auto import 

After installing ACM, enable the **Cluster API (CAPI)** and **Cluster API Provider AWS (CAPA)** features in the `MultiClusterEngine` resource.

1. Verify the default MultiClusterEngine CR has been created. 

	```shell
	 oc get multiclusterengine engine 
	 NAME     STATUS      AGE   CURRENTVERSION   DESIREDVERSION
	 engine   Available   11d   2.10.0            2.10.0
	```

2. Edit the MultiClusterEngine engine to enable cluster-api and cluster-api-provider-aws components.\ **Note:** The hypershift components must be disabled before enabling cluster-api and cluster-api-provider-aws components.

	`oc edit multiclusterengine engine`

	Enable the following components:

	```yaml
	    - configOverrides: {}
	      enabled: false
	      name: hypershift
	    - configOverrides: {}
	      enabled: false
	      name: hypershift-local-hosting
	    - configOverrides: {}
	      enabled: true
	      name: cluster-api
	    - configOverrides: {}
	      enabled: true
	      name: cluster-api-provider-aws

	```

	The changes are automatically saved. 

3. Verify the CAPI & CAPA deployments were installed.

	```shell
	oc get deploy -n multicluster-engine
	NAME                                  READY   UP-TO-DATE   AVAILABLE   AGE
	capa-controller-manager               1/1     1            1           12d
	capi-controller-manager               1/1     1            1           12d
	```

4. Verify the ClusterManager CR cluster-manager was created.
	```
	oc get ClusterManager
	NAME              AGE
	cluster-manager   12d
	```

5. Edit the cluster-manager to enable auto import.

	`oc edit ClusterManager cluster-manager`

	Add the registrationConfiguration section as shown below:

	```yaml
	apiVersion: operator.open-cluster-management.io/v1
	kind: ClusterManager
	metadata:
	  name: cluster-manager
	spec:
	  registrationConfiguration:
	    featureGates:
	    - feature: ClusterImporter
	      mode: Enable
	    - feature: ManagedClusterAutoApproval
	      mode: Enable
	    autoApproveUsers:
	    - system:serviceaccount:multicluster-engine:agent-registration-bootstrap
	```

	Bind the CAPI manager permission to the import controller by applying the ClusterRoleBinding below.

	```yaml
	apiVersion: rbac.authorization.k8s.io/v1
	kind: ClusterRoleBinding
	metadata:
	  name: cluster-manager-registration-capi
	roleRef:
	  apiGroup: rbac.authorization.k8s.io
	  kind: ClusterRole
	  name: capi-operator-manager-role
	subjects:
	- kind: ServiceAccount
	  name: registration-controller-sa
	  namespace: open-cluster-management-hub
	```

## Permissions
### AWS credentials

1. Set the AWS credentials using the access key created earlier. Run the command below after setting the AWS values and region.

	```shell
	echo '[default]
	aws_access_key_id = <your-access-key>
	aws_secret_access_key = <your-secret-access-key>
	region = us-east-1
	' | base64 -w 0
	```

	If you are using Multi-Factor Auth with AWS use the below command instead with the session token.

	```shell
	echo '[default]
	aws_access_key_id = <your-access-key>
	aws_secret_access_key = <your-secret-access-key>
	aws_session_token= <your-aws-session-token>
	region = us-east-1
	' | base64 -w 0
	```

2. Update the capa-manager-bootstrap-credentials secret.   
Copy the output of the previous command and add it to the capa-manager-bootstrap-credentials secret.

	`oc edit secret -n multicluster-engine capa-manager-bootstrap-credentials`

	Make the changes to the data->credentials field as shown below:

	```yaml
	apiVersion: v1
	data:
	  credentials: <REPLACE_WITH_AWS_CREDENTIALS>
	kind: Secret
	metadata:
	  name: capa-manager-bootstrap-credentials
	  namespace: multicluster-engine
	```

3. Restart the capa-controller-manager deployment.

	`oc rollout restart deployment capa-controller-manager -n multicluster-engine`

### OCM Authentication
CAPA controller requires Redhat OCM credentials to provision ROSA HCP.

1. Create a Kubernetes secret in the target namespace with the previously created Redhat service account credentials. The `ROSAControlPlane` resource will reference this secret during cluster provisioning. In the example below; the `ns-rosa-hcp` namespace is used to create all required CRs
   
    ```shell
	oc create namespace ns-rosa-hcp
    oc -n ns-rosa-hcp create secret generic rosa-creds-secret \
      --from-literal=ocmClientID='....' \
      --from-literal=ocmClientSecret='eyJhbGciOiJIUzI1NiIsI....' \
      --from-literal=ocmApiUrl='https://api.openshift.com'
    ```
    **Note:** to consume the secret without the need to reference it from your `ROSAControlPlane`, name your secret as `rosa-creds-secret` and create it under namespace `multicluster-engine`.
    ```shell
    oc -n multicluster-engine create secret generic rosa-creds-secret \
      --from-literal=ocmClientID='....' \
      --from-literal=ocmClientSecret='eyJhbGciOiJIUzI1NiIsI....' \
      --from-literal=ocmApiUrl='https://api.openshift.com'
    ```

## Creating the ROSA-HCP cluster

1. Create the AWSClusterControllerIdentity as below.

    ```yaml
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: AWSClusterControllerIdentity
    metadata:
      name: "default"
    spec:
      allowedNamespaces: {}  # matches all namespaces
    ```

1. Create the ROSARoleConfig and ROSANetwork as below.

	```yaml
	apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
	kind: ROSARoleConfig
	metadata:
	  name: "role-config"
	  namespace: "ns-rosa-hcp"
	spec:
	  accountRoleConfig:
	    prefix: "rosa"
	    version: "4.20.0"  
	  operatorRoleConfig:
	    prefix: "rosa"
	  credentialsSecretRef:
	    name: rosa-creds-secret
	  oidcProviderType: Managed
	---
	apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
	kind: ROSANetwork
	metadata:
	  name: "rosa-vpc"
	  namespace: "ns-rosa-hcp"
	spec:
	  region: "us-west-2"
	  stackName: "rosa-hcp-net"
	  availabilityZones:
	  - "us-west-2a"
	  - "us-west-2b"
	  - "us-west-2c"
	  cidrBlock: 10.0.0.0/16
	  identityRef:
	    kind: AWSClusterControllerIdentity
	    name: default
	```
	Verify the ROSARoleConfig was successfully created. The ROSARoleConfig status should contain the accountRolesRef, oidcID, oidcProviderARN and operatorRolesRef.

	```shell
	oc get rosaroleconfig  -n ns-rosa-hcp role-config -o yaml

	apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
	kind: ROSARoleConfig
	metadata:
	  name: "role-config"
	  namespace: "ns-rosa-hcp"
	spec:
	...
	status:
	  accountRolesRef:
	    installerRoleARN: arn:aws:iam::123456789123:role/rosa-HCP-ROSA-Installer-Role
	    supportRoleARN: arn:aws:iam::123456789123:role/rosa-HCP-ROSA-Support-Role
	    workerRoleARN: arn:aws:iam::123456789123:role/rosa-HCP-ROSA-Worker-Role
	  conditions:
	  - lastTransitionTime: "2025-11-03T18:12:09Z"
	    status: "True"
	    type: Ready
	  - lastTransitionTime: "2025-11-03T18:12:09Z"
	    message: RosaRoleConfig is ready
	    reason: Created
	    severity: Info
	    status: "True"
	    type: RosaRoleConfigReady
	  oidcID: anyoidcanyoidctuq4b
	  oidcProviderARN: arn:aws:iam::123456789123:oidc-provider/oidc.os1.devshift.org/anyoidcanyoidctuq4b
	  operatorRolesRef:
	    controlPlaneOperatorARN: arn:aws:iam::123456789123:role/rosa-kube-system-control-plane-operator
	    imageRegistryARN: arn:aws:iam::123456789123:role/rosa-openshift-image-registry-installer-cloud-credentials
	    ingressARN: arn:aws:iam::123456789123:role/rosa-openshift-ingress-operator-cloud-credentials
	    kmsProviderARN: arn:aws:iam::123456789123:role/rosa-kube-system-kms-provider
	    kubeCloudControllerARN: arn:aws:iam::123456789123:role/rosa-kube-system-kube-controller-manager
	    networkARN: arn:aws:iam::123456789123:role/rosa-openshift-cloud-network-config-controller-cloud-credentials
	    nodePoolManagementARN: arn:aws:iam::123456789123:role/rosa-kube-system-capa-controller-manager
	    storageARN: arn:aws:iam::471112697682:role/rosa-openshift-cluster-csi-drivers-ebs-cloud-credentials
	```
	Verify the ROSANetwork was successfully created. The ROSANetwork status should contain the created subnets.

	```shell
	oc get rosanetwork -n ns-rosa-hcp rosa-vpc -o yaml

	apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
	kind: ROSANetwork
	metadata:
	  name: "rosa-vpc"
	  namespace: "ns-rosa-hcp"
	spec:
	  ...
	status:
	  conditions:
	  - lastTransitionTime: "2025-11-03T18:15:05Z"
	    reason: Created
	    severity: Info
	    status: "True"
	    type: ROSANetworkReady
	  resources:
	    ...
	  subnets:
	  - availabilityZone: us-west-2a
	    privateSubnet: subnet-084ebac3893fc14ff
	    publicSubnet: subnet-0ec9fa706a26519ee
	  - availabilityZone: us-west-2b
	    privateSubnet: subnet-07727689065612f6e
	    publicSubnet: subnet-0bb2220505b16f606
	  - availabilityZone: us-west-2c
	    privateSubnet: subnet-002e071b9624727f3
	    publicSubnet: subnet-049fa2a528d896356
	```

1. Create the required CRs for `ROSAControlPlane`  as below.

	```yaml
	apiVersion: cluster.open-cluster-management.io/v1
	kind: ManagedCluster
	metadata:
	  name: rosa-hcp-1
	spec:
	  hubAcceptsClient: true
	---
	apiVersion: cluster.x-k8s.io/v1beta1
	kind: Cluster
	metadata:
	  name: "rosa-hcp-1"
	  namespace: "ns-rosa-hcp"
	spec:
	  clusterNetwork:
	    pods:
	      cidrBlocks: ["192.168.0.0/16"]
	  infrastructureRef:
	    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
	    kind: ROSACluster
	    name: "rosa-hcp-1"
	    namespace: "ns-rosa-hcp"
	  controlPlaneRef:
	    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
	    kind: ROSAControlPlane
	    name: "rosa-cp-1"
	    namespace: "ns-rosa-hcp"
	---
	apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
	kind: ROSACluster
	metadata:
	  name: "rosa-hcp-1"
	  namespace: "ns-rosa-hcp"
	spec: {}
	---
	apiVersion: controlplane.cluster.x-k8s.io/v1beta2
	kind: ROSAControlPlane
	metadata:
	  name: "rosa-cp-1"
	  namespace: "ns-rosa-hcp"
	spec:
	  credentialsSecretRef:
	    name: rosa-creds-secret
	  rosaClusterName: rosa-hcp-1
	  domainPrefix: rosa-hcp
	  rosaRoleConfigRef:
	    name: role-config
	  version: "4.20.0"
	  ## The region should match the aws region used to create the ROSANetwork
	  region: "us-west-2"
	  rosaNetworkRef:
	    name: "rosa-vpc"
	  network:
	    machineCIDR: "10.0.0.0/16"
	    podCIDR: "10.128.0.0/14"
	    serviceCIDR: "172.30.0.0/16"
	  defaultMachinePoolSpec:
	    instanceType: "m5.xlarge"
	    autoscaling:
	      maxReplicas: 6
	      minReplicas: 3
	  additionalTags:
	    env: "demo"
	    profile: "hcp"
	```
1. Check the ROSAControlPlane status.

	```shell
	oc get ROSAControlPlane rosa-cp-1 -n ns-rosa-hcp

	NAMESPACE     NAME        CLUSTER      READY
	ns-rosa-hcp   rosa-cp-1   rosa-hcp-1   true
	```

	The ROSA HCP cluster could take around 40 minutes to be fully provisioned.

1. After the ROSAControlPlane provisioning has completed, verify the ROSAMachinePool was successfully created.
   **Note:** The default available ROSAMachinePools count based on the assigned availability Zones.

	```shell
	oc get ROSAMachinePool -n ns-rosa-hcp

	NAMESPACE     NAME        READY   REPLICAS
	ns-rosa-hcp   workers-0   true    1
	ns-rosa-hcp   workers-1   true    1
	ns-rosa-hcp   workers-2   true    1
	```
## Delete ROSA-HCP cluster

Deleting the ROSAControlPlane initiates the full deprovisioning of the ROSA-HCP cluster, which typically takes 30–50 minutes to complete. The associated ROSAMachinePool resources will be automatically deleted as part of this cascade process.

Use the following command to delete the ROSAControlPlane Custom Resource (CR) along with the associated Cluster CR:

```shell
oc delete -n ns-rosa-hcp cluster/rosa-hcp-1 rosacontrolplane/rosa-cp-1
```

Once the ROSAControlPlane deletion is complete, you may proceed with deleting the ROSARoleConfig and ROSANetwork resources.


## Support

When creating an issue for ROSA HCP cluster, include logs for the capa-controller-manager and capi-controller-manager deployment pods. 
The logs can be saved to text file using the commands below:

```shell
  oc get pod -n multicluster-engine
NAME                                      READY   STATUS    RESTARTS   AGE
capa-controller-manager-77f5b946b-sddcg   1/1     Running   1          3d3h

  oc logs -n multicluster-engine capa-controller-manager-77f5b946b-sddcg > capa-controller-manager-logs.txt

  oc get pod -n multicluster-engine
NAME                                       READY   STATUS    RESTARTS   AGE
capi-controller-manager-78dc897784-f8gpn   1/1     Running   18         26d

  oc logs -n multicluster-engine capi-controller-manager-78dc897784-f8gpn > capi-controller-manager-logs.txt
```

Include all the resources used to create the ROSA HCP cluster:
- `Cluster`
- `ROSAControlPlane`
- `MachinePool`
- `ROSAMachinePool`
- `ROSARoleConfig`
- `ROSANetwork`
