# Enable IAM Roles on the Management Cluster using Cluster API Provider AWS (CAPA)

Users may want to use IAM roles when deploying a management cluster. If a management cluster already exists and was created using AWS
credentials, CAPA provides a mechanism to switch from credentials to IAM roles.

## Prerequisites

1.  A bootstrap cluster (OCP or ROSA-HCP) created using AWS credentials.\
    These credentials can be temporary. To generate temporary
    credentials, refer to the AWS [documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_request.html)

2.  After installing the bootstrap cluster, log in to it and install the
    ACM operator.

## Enable CAPI, CAPA, and Configure IAM Role

1.  Once ACM is installed, edit the `MultiClusterEngine` resource to enable cluster-api and cluster-api-provider-aws components.\
    **Note:** Hypershift components must be disabled before enabling
    Cluster API and Cluster API Provider AWS.

    ``` shell
    oc edit multiclusterengine engine
    ```

    Enable/disable the following components:

    ``` yaml
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

2.  Verify that CAPI and CAPA deployments are running:

    ``` shell
    oc get deploy -n multicluster-engine
    NAME                                  READY   UP-TO-DATE   AVAILABLE   AGE
    capa-controller-manager               1/1     1            1           12d
    capi-controller-manager               1/1     1            1           12d
    ```

3.  Pause the `MultiClusterEngine` CR to allow updating the CAPA
    controller service account:

    ``` shell
    oc annotate mce multiclusterengine installer.multicluster.openshift.io/pause=true
    ```

4.  Retrieve OIDC provider details and set your AWS account ID:

    ``` shell
    export OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -ojson | jq -r .spec.serviceAccountIssuer | sed 's/https:\/\///')
    export AWS_ACCOUNT_ID={YOUR_AWS_ACCOUNT_ID}
    ```

5.  Create the trust policy for the `capa-controller-manager` IAM role:

        cat <<EOF > ./trust.json
        {
          "Version": "2012-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
              },
              "Action": "sts:AssumeRoleWithWebIdentity",
              "Condition": {
                "StringEquals": {
                  "${OIDC_PROVIDER}:sub": "system:serviceaccount:multicluster-engine:capa-controller-manager"
                }
              }
            }
          ]
        }
        EOF

6.  Create the IAM role and attach the required AWS policies:

        aws iam create-role --role-name "capa-manager-role" --assume-role-policy-document file://trust.json --description "IAM role for CAPA to assume"

        aws iam attach-role-policy --role-name capa-manager-role --policy-arn arn:aws:iam::aws:policy/AWSCloudFormationFullAccess

        aws iam attach-role-policy --role-name capa-manager-role --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

7.  Retrieve the IAM role ARN:

        export APP_IAM_ROLE_ARN=$(aws iam get-role --role-name=capa-manager-role --query Role.Arn --output text)

        export IRSA_ROLE_ARN=eks.amazonaws.com/role-arn=$APP_IAM_ROLE_ARN

8.  Annotate the service account with the IAM role ARN and restart the
    CAPA deployment:

    ``` shell
    oc annotate serviceaccount -n multicluster-engine capa-controller-manager $IRSA_ROLE_ARN

    oc rollout restart deployment capa-controller-manager -n multicluster-engine
    ```

After this configuration, you can use `cluster-api-provider-aws` to
create ROSA-HCP clusters without storing AWS credentials in the
management cluster.