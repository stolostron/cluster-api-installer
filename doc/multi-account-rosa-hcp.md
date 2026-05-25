# Multi-Account ROSA HCP Deployment Using AWS Identity Objects

This guide explains how to use `AWSClusterControllerIdentity` and `AWSClusterRoleIdentity` to deploy ROSA HCP resources (`ROSARoleConfig`, `ROSANetwork`, and `ROSAControlPlane`) into AWS accounts different from the one where your management cluster (CAPA controller) runs.

## Overview

This guide assumes the management cluster already uses **IRSA** (IAM Roles for Service Accounts) to authenticate the CAPA controller, as described in [Enable_iam_roles_capa.md](Enable_iam_roles_capa.md). That gives the CAPA controller a management-account IAM role (`capa-manager-role`) via `sts:AssumeRoleWithWebIdentity`.

To deploy ROSA into a **separate target AWS account**, you extend that chain with two additional steps:

1. Grant `capa-manager-role` permission to call `sts:AssumeRole` on a role in the target account.
2. Create that role in the target account with a trust policy that explicitly allows `capa-manager-role` to assume it.

On the Kubernetes side, two cluster-scoped objects represent this chain:

- `AWSClusterControllerIdentity` — represents the CAPA controller's existing IRSA-backed identity in the management account.
- `AWSClusterRoleIdentity` — references the controller identity as its source and carries the target account role ARN. CAPA uses it to assume that role before making any AWS API calls for resources that reference it.

Each ROSA resource (`ROSARoleConfig`, `ROSANetwork`, `ROSAControlPlane`) then references the `AWSClusterRoleIdentity`, ensuring all AWS operations run in the target account.

## Prerequisites

This guide assumes the management cluster is already configured to use **IAM Roles for Service Accounts (IRSA)** for the CAPA controller, as described in [Enable_iam_roles_capa.md](Enable_iam_roles_capa.md). That guide creates:

- An IAM role named `capa-manager-role` in the **management account**, trusted by the management cluster's OIDC provider via `sts:AssumeRoleWithWebIdentity`.
- The CAPA controller service account annotated with that role's ARN.

The cross-account setup in this guide extends that existing role — no new management-account role is needed.

## Architecture

```
Management Account (CAPA controller runs here)
│
│  capa-controller-manager (ServiceAccount)
│       │  sts:AssumeRoleWithWebIdentity  (IRSA — set up by Enable_iam_roles_capa.md)
│       ▼
│  capa-manager-role  (IAM Role, management account)
│       │  sts:AssumeRole  (cross-account — added in Step 1.1 below)
│       ▼
Target Account (ROSA cluster lives here)
│  rosa-deployment-role  (IAM Role, target account — created in Step 1.2 below)
│       │  used by
│       ▼
│  AWSClusterRoleIdentity ──► ROSARoleConfig
│                         ──► ROSANetwork
│                         ──► ROSAControlPlane
```

## Step 1: IAM Role Setup

### 1.1 Management Account — Allow `capa-manager-role` to Assume the Target Role

The `capa-manager-role` created by [Enable_iam_roles_capa.md](Enable_iam_roles_capa.md) already has the permissions needed to manage CloudFormation and VPC resources. You only need to add a permission that lets it call `sts:AssumeRole` on the role you will create in the target account.

Run the following while authenticated to the **management account**:

```shell
# Retrieve the management account ID
export MANAGEMENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat <<EOF > capa-assume-role-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::*:role/rosa-deployment-role"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name capa-manager-role \
  --policy-name AllowAssumeTargetAccountRole \
  --policy-document file://capa-assume-role-policy.json
```

Retrieve the `capa-manager-role` ARN — you will need it when creating the target account trust policy:

```shell
export CAPA_MANAGER_ROLE_ARN=$(aws iam get-role \
  --role-name capa-manager-role \
  --query Role.Arn --output text)
echo $CAPA_MANAGER_ROLE_ARN
# arn:aws:iam::<MANAGEMENT_ACCOUNT_ID>:role/capa-manager-role
```

### 1.2 Target Account — Create `rosa-deployment-role` with Cross-Account Trust

Run the following while authenticated to the **target account**. The trust policy grants `capa-manager-role` from the management account permission to assume this role via `sts:AssumeRole`.

#### Create the trust policy

```shell
# Set to the CAPA_MANAGER_ROLE_ARN value from Step 1.1
export CAPA_MANAGER_ROLE_ARN="arn:aws:iam::<MANAGEMENT_ACCOUNT_ID>:role/capa-manager-role"

cat <<EOF > rosa-deployment-trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "${CAPA_MANAGER_ROLE_ARN}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
```

#### Create the role

```shell
aws iam create-role \
  --role-name rosa-deployment-role \
  --assume-role-policy-document file://rosa-deployment-trust.json \
  --description "Role assumed by CAPA (management account) to deploy ROSA HCP in this account"
```

#### Attach the required ROSA permissions

ROSA provisioning requires permissions to manage CloudFormation stacks, VPCs, IAM roles, OIDC providers, and related resources. Attach the AWS-managed policies first:

```shell
aws iam attach-role-policy \
  --role-name rosa-deployment-role \
  --policy-arn arn:aws:iam::aws:policy/AWSCloudFormationFullAccess

aws iam attach-role-policy \
  --role-name rosa-deployment-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

aws iam attach-role-policy \
  --role-name rosa-deployment-role \
  --policy-arn arn:aws:iam::aws:policy/ROSAManageSubscription

aws iam attach-role-policy \
  --role-name rosa-deployment-role \
  --policy-arn arn:aws:iam::aws:policy/ROSACloudWatchOperatorPolicy
```

Attach `IAMFullAccess` to cover all IAM operations CAPA needs to create ROSA account roles, operator roles, and the OIDC provider:

```shell
aws iam attach-role-policy \
  --role-name rosa-deployment-role \
  --policy-arn arn:aws:iam::aws:policy/IAMFullAccess
```

`IAMFullAccess` grants `iam:*` but does not cover STS actions. Attach a small inline policy for the STS permissions the role still requires:

```shell
cat <<EOF > rosa-sts-inline.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRole",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name rosa-deployment-role \
  --policy-name ROSADeploymentSTSPolicy \
  --policy-document file://rosa-sts-inline.json
```

Retrieve the target role ARN — you will need it when creating the `AWSClusterRoleIdentity`:

```shell
export TARGET_ROLE_ARN=$(aws iam get-role \
  --role-name rosa-deployment-role \
  --query Role.Arn --output text)
echo $TARGET_ROLE_ARN
# arn:aws:iam::<TARGET_ACCOUNT_ID>:role/rosa-deployment-role
```

**Summary of the resulting trust chain:**

```
capa-controller-manager (ServiceAccount, multicluster-engine namespace)
  └─ AssumeRoleWithWebIdentity (IRSA, management account OIDC provider)
       └─ capa-manager-role  (management account)
            └─ AssumeRole (cross-account)
                 └─ rosa-deployment-role  (target account)
```

## Step 2: Create AWS Identity Objects

Identity objects are **cluster-scoped** (no namespace). Create them once on the management cluster.

### 2.1 AWSClusterControllerIdentity

This object represents the CAPA controller's own credentials. It must exist before any `AWSClusterRoleIdentity` can reference it.

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSClusterControllerIdentity
metadata:
  name: default
spec:
  allowedNamespaces: {}  # allow use from any namespace
```

```shell
oc apply -f awsclustercontrolleridentity.yaml
```

### 2.2 AWSClusterRoleIdentity

This object tells CAPA to assume the target account role before making any AWS API calls for resources that reference it.

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: AWSClusterRoleIdentity
metadata:
  name: target-account-identity   # choose a descriptive name
spec:
  allowedNamespaces:
    list:
    - ns-rosa-hcp
  roleARN: "arn:aws:iam::<TARGET_ACCOUNT_ID>:role/rosa-deployment-role"
  sessionName: "capa-rosa-session"
  durationSeconds: 10800          # 3 hours; valid range 900–43200
  sourceIdentityRef:
    kind: AWSClusterControllerIdentity
    name: default
```

If you added an `externalId` condition to the trust policy, include it here:

```yaml
spec:
  externalID: "rosa-cluster-deployment"
  # ... other fields as above
```

```shell
oc apply -f awsclusterroleidentity.yaml
```

Repeat this step with a different `name` and `roleARN` for each additional target account.

## Step 3: Create ROSA Resources Targeting the Target Account

All three ROSA resources accept an `identityRef` that points to the `AWSClusterRoleIdentity`. Set this field on every resource so all AWS operations go to the correct account.

### Prerequisites

Create the namespace and OCM credentials secret in the target namespace:

```shell
oc create namespace ns-rosa-hcp

oc -n ns-rosa-hcp create secret generic rosa-creds-secret \
  --from-literal=ocmClientID='<your-ocm-client-id>' \
  --from-literal=ocmClientSecret='<your-ocm-client-secret>' \
  --from-literal=ocmApiUrl='https://api.openshift.com'
```

### 3.1 ROSARoleConfig

`ROSARoleConfig` creates the ROSA account roles, operator roles, and OIDC provider in the **target account**. Reference the `AWSClusterRoleIdentity` via `identityRef`.

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ROSARoleConfig
metadata:
  name: role-config
  namespace: ns-rosa-hcp
spec:
  accountRoleConfig:
    prefix: "rosa"      # up to 4 characters; prefix for all account IAM roles
    version: "4.20.0"   # OpenShift version the roles are tied to
  operatorRoleConfig:
    prefix: "rosa"      # up to 4 characters; prefix for all operator IAM roles
  credentialsSecretRef:
    name: rosa-creds-secret
  oidcProviderType: Managed
  identityRef:
    kind: AWSClusterRoleIdentity
    name: target-account-identity   # references the identity created in step 2.2
```

Wait for the `ROSARoleConfig` to become ready before continuing:

```shell
oc get rosaroleconfig -n ns-rosa-hcp role-config -o yaml
```

The status should show `accountRolesRef`, `oidcID`, `oidcProviderARN`, and `operatorRolesRef` populated.

### 3.2 ROSANetwork

`ROSANetwork` creates a CloudFormation stack with a VPC and subnets in the **target account**. Reference the same `AWSClusterRoleIdentity`.

```yaml
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ROSANetwork
metadata:
  name: rosa-vpc
  namespace: ns-rosa-hcp
spec:
  region: "us-west-2"          # AWS region in the TARGET account
  stackName: "rosa-hcp-net"    # CloudFormation stack name
  cidrBlock: "10.0.0.0/16"
  availabilityZones:
  - "us-west-2a"
  - "us-west-2b"
  - "us-west-2c"
  identityRef:
    kind: AWSClusterRoleIdentity
    name: target-account-identity
```

Wait for the `ROSANetwork` to become ready:

```shell
oc get rosanetwork -n ns-rosa-hcp rosa-vpc -o yaml
```

The status should list subnets for each availability zone.

### 3.3 ROSAControlPlane

`ROSAControlPlane` provisions the ROSA HCP control plane using the roles and network created above.

```yaml
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: rosa-hcp-1
  namespace: ns-rosa-hcp
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["192.168.0.0/16"]
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: ROSACluster
    name: rosa-hcp-1
    namespace: ns-rosa-hcp
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta2
    kind: ROSAControlPlane
    name: rosa-cp-1
    namespace: ns-rosa-hcp
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: ROSACluster
metadata:
  name: rosa-hcp-1
  namespace: ns-rosa-hcp
spec: {}
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta2
kind: ROSAControlPlane
metadata:
  name: rosa-cp-1
  namespace: ns-rosa-hcp
spec:
  rosaClusterName: rosa-hcp-1
  domainPrefix: rosa-hcp
  version: "4.20.0"
  region: "us-west-2"
  credentialsSecretRef:
    name: rosa-creds-secret
  rosaRoleConfigRef:
    name: role-config        # references the ROSARoleConfig above
  rosaNetworkRef:
    name: rosa-vpc           # references the ROSANetwork above
  network:
    machineCIDR: "10.0.0.0/16"
    podCIDR: "10.128.0.0/14"
    serviceCIDR: "172.30.0.0/16"
  defaultMachinePoolSpec:
    instanceType: "m5.xlarge"
    autoscaling:
      minReplicas: 3
      maxReplicas: 6
  identityRef:
    kind: AWSClusterRoleIdentity
    name: target-account-identity
  additionalTags:
    env: "demo"
    account: "target-a"
```

Check provisioning progress:

```shell
oc get ROSAControlPlane rosa-cp-1 -n ns-rosa-hcp
# NAMESPACE     NAME       CLUSTER     READY
# ns-rosa-hcp   rosa-cp-1  rosa-hcp-1  true
```

ROSA HCP provisioning typically takes 30–40 minutes.

## Deploying to Multiple Target Accounts

To deploy additional ROSA clusters in different AWS accounts, repeat Steps 1.2 and 2.2 for each account and use a unique identity name per account. Each set of ROSA resources then references its own identity:

```
Account A:
  AWSClusterRoleIdentity  name: account-a-identity  roleARN: arn:aws:iam::<ACCOUNT_A>:role/rosa-deployment-role
  ROSARoleConfig          identityRef.name: account-a-identity
  ROSANetwork             identityRef.name: account-a-identity
  ROSAControlPlane        identityRef.name: account-a-identity

Account B:
  AWSClusterRoleIdentity  name: account-b-identity  roleARN: arn:aws:iam::<ACCOUNT_B>:role/rosa-deployment-role
  ROSARoleConfig          identityRef.name: account-b-identity
  ROSANetwork             identityRef.name: account-b-identity
  ROSAControlPlane        identityRef.name: account-b-identity
```

All identity objects are cluster-scoped and can be shared across namespaces using `allowedNamespaces`.

## Restricting Namespace Access

By default `allowedNamespaces: {}` permits any namespace to reference the identity. To restrict it to specific namespaces use a list or a label selector:

```yaml
# Allow only explicitly listed namespaces
spec:
  allowedNamespaces:
    list:
    - ns-rosa-hcp
    - ns-rosa-prod

# Allow namespaces matching a label selector
spec:
  allowedNamespaces:
    selector:
      matchLabels:
        rosa-enabled: "true"
```

## Troubleshooting

**`sts:AssumeRole` denied** - Confirm that:
- The `capa-manager-role` ARN in the target account trust policy exactly matches the ARN output from Step 1.1.
- The `AllowAssumeTargetAccountRole` inline policy was added to `capa-manager-role` in the management account.

Verify the identity CAPA is running as:
```shell
# From the management cluster, check what identity the CAPA pod resolves to
oc exec -n multicluster-engine deployment/capa-controller-manager -- \
  aws sts get-caller-identity
```

**`ROSARoleConfig` stuck not ready** - Check the CAPA controller logs for IAM or STS errors:
```shell
oc logs -n multicluster-engine deployment/capa-controller-manager | grep -i "role-config\|rosaroleconfig\|sts\|iam"
```

**`ROSANetwork` stack creation failed** - Inspect the CloudFormation stack events in the target account:
```shell
aws cloudformation describe-stack-events --stack-name rosa-hcp-net \
  --profile <target-account-profile>
```

**Identity not allowed in namespace** - Verify that `allowedNamespaces` in the `AWSClusterRoleIdentity` or `AWSClusterControllerIdentity` includes the namespace where your ROSA resources live.
