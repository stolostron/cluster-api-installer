# Provisioning ARO using CAPZ and ASO

The necessary infrastructure for deploying an ARO-HCP cluster can be provisioned using a declarative approach with [Azure Service Operator v2](https://azure.github.io/azure-service-operator/)
as part of the Cluster API Provider for Azure. In the following steps, we will create the required Azure resources,
including a Resource Group, Network Security Group, Virtual Network (VNet), Subnet, Key Vault, User Assigned Managed Identities, and Role Assignments.


## Prerequisites

We expect the following:

* Docker or Podman with `kind` cluster is being used OR Openshift cluster v4.18 or Later  
* The following tools are installed:  
  * `az` CLI (or a `sp.json` file is already created), see [Install the Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli?view=azure-cli-latest)
  * `oc` - see [OpenShift CLI (oc)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.18/html/cli_tools/openshift-cli-oc)
  * `helm` – also required for setting up the infrastructure using the declarative approach
  * `clusterctl` - see [The clusterctl CLI tool](https://cluster-api-aws.sigs.k8s.io/getting-started#install-clusterctl)
* Ensure you have access to the RH Azure tenant:
  * **RH account**: You need to have a Red Hat account to access the Red Hat Azure tenant (`redhat0.onmicrosoft.com`) where personal DEV environments are created
  * **Subscription access**: You need access to the `ARO Hosted Control Planes (EA Subscription 1)` subscription in the Red Hat Azure tenant. Consult the [ARO HCP onboarding guide](https://docs.google.com/document/d/1KUZSLknIkSd6usFPe_OcEYWJyW6mFeotc2lIsLgE3JA/)
  * `az login` with your Red Hat account
* It's not possible to use `az cli` with Python 3.14, see a possible fix - https://github.com/RadekCap/CAPZTests/blob/main/docs/FEDORA-43-AZURE-CLI.md

## Provisioning ARO

1. Check out the deployment:
```
git clone -b installer-aro https://github.com/stolostron/cluster-api-installer.git installer-aro
cd installer-aro
```

2. The next command will prepare an instance of a kind cluster (with cert manager, CAPI, CAPZ and ASO):
```
USER=ad KIND_CLUSTER_NAME=capz-stage ./scripts/deploy-charts-kind-capz.sh
```
Please keep the `USER` value shorter than 5 charasters and `KIND_CLUSTER_NAME` shorter than 10 characters.

3. Edit the variables in the script (if needed): ./doc/aro-hcp-scripts/aro-hcp-gen.sh
```
export USER=${USER:-user1}
export CS_CLUSTER_NAME=${CS_CLUSTER_NAME:-$USER-$ENV}
export NAME_PREFIX=${NAME_PREFIX:-$CS_CLUSTER_NAME}
export RESOURCEGROUPNAME="$CS_CLUSTER_NAME-resgroup"
export OCP_VERSION=${OCP_VERSION:-4.20}
export OCP_VERSION_MP=${OCP_VERSION_MP:-$OCP_VERSION.0}
export REGION=${REGION:-westus3}
```

4. The next command (please use your right values for REGION, USER, ENV and AZURE_SUBSCRIPTION_NAME) will generate:
 * `sp-$SUBSCRIPTION_ID.json` file with generated ServicePrincipal (named `$USER-sp-$randomIdentifier`) which has the assigned role `Custom-Owner (Block Billing and Subscription deletion)` for the specified subscription
 * `operators-uamis-suffix.txt` - Random name suffix used for User Assigned Identities
 * YAML files with k8s resources:
   * `aro-stage/credentials.yaml` - `Secret/aso-secret` & `AzureClusterIdentity/cluster-identity` & `Secret/cluster-identity-secret`
   * `aro-stage/is.yaml` - Infrastructure required for ARO HCP cluster: `ResourceGroup`, `NetworkSecurityGroup`, `VirtualNetwork`, `VirtualNetworksSubnet`, `Vault`, `UserAssignedIdentity`s, `RoleAssignment`s
   * `aro-stage/aro.yaml` - `AROControlPlane`, `AROCluster`, `Cluster`, `AROMachinePool` and `MachinePool`

Simple deployment for stage:
```
ENV=stage ./doc/aro-hcp-scripts/aro-hcp-gen.sh aro-stage
```

For pruduction we can use e.g.:
```
REGION="switzerlandnorth" USER=mveber4 AZURE_SUBSCRIPTION_NAME="974ebd46-8ad3-41e3-afef-7ef25fd5c371" \
ENV=prod ./doc/aro-hcp-scripts/aro-hcp-gen.sh aro-prod
```

5. Apply the YAML files with resources (YAMLs from the directory in the specified order):
```
(cd aro-stage; oc apply -f credentials.yaml -f is.yaml -f aro.yaml)
```

6. You need the upstream `clusterctl` to monitor, e.g.:
```
cd ..
git clone -b main https://github.com/kubernetes-sigs/cluster-api.git cluster-api-main
cd cluster-api-main
make clusterctl
watch -n 5 --color --no-wrap ./bin/clusterctl describe cluster "<your-cluster-name>" --color --show-conditions=all
```

7. You can get the kubeconfig for the provisioned cluster:
  * Using `oc` and `base64`:
    ```
    oc get secret mveber-stage-kubeconfig -o jsonpath='{.data.value}' | base64 -d > /tmp/kc.yaml
    ```
  * Or using `clusterctl`:
    ```
    ./bin/clusterctl get kubeconfig mveber-aro > /tmp/kc.yaml
    ```

8. Then you can see the nodes:
```
KUBECONFIG=/tmp/kc.yaml oc get nodes
```

## External Authentication Configuration

If your ARO cluster is configured with External Authentication (Azure AD integration), you need to run the post-deployment configuration script to complete the setup:

9. Run the External Authentication post-deployment script:
```
./doc/aro-hcp-scripts/ea-post-deploy-update.sh aro-stage/aro.yaml
```

This script will:
* Extract cluster information and External Auth configuration from your aro.yaml
* Update the Azure AD application with the correct redirect URIs
* Enable ID token issuance and configure group claims
* Create required secrets for console authentication on both management and workload clusters
* Set up cluster role bindings for your user and the engineering group

**Note**: This step is only required for clusters using External Authentication. Skip this if you're using standard cluster authentication.


