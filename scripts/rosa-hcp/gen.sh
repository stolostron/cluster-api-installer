#!/bin/bash
if [ -n "$1" ] ; then
    GEN_OUTPUT="$1"; shift
else
    echo "usage: $0 <output-dir>"
    exit 1
fi
set -e

export DOMAIN_PREFIX=${DOMAIN_PREFIX:-"${USER:0:4}"} # only 4 chars
export CLUSTER_NAME=${WORKLOAD_CLUSTER_NAME:-"$CLUSTER_NAME"}
export CLUSTER_NAME=${CLUSTER_NAME:-"rosa-$USER"}
export ROLE_PREFIX=${ROLE_PREFIX:-"$DOMAIN_PREFIX"}
export NAMESPACE=${NAMESPACE:-"rosa-ns"}
export OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-"4.20.0"}
export AWS_REGION=${AWS_REGION:-"us-west-2"}
export ROLE_CONFIG=${ROLE_CONFIG:-"role-config"}
export ROSA_VPC=${ROSA_VPC:-"rosa-vpc"}
export ROSA_CREDS_SECRET=${ROSA_CREDS_SECRET:-"rosa-creds-secret"}
export OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-"4.20.0"}
export CAPA_NAMESPACE=${CAPA_NAMESPACE:-"capa-system"}

echo USER=$USER, DOMAIN_PREFIX=$DOMAIN_PREFIX, CLUSTER_NAME=$CLUSTER_NAME

# credentials
if [ -s "$JSON_SECRET_FILE" ] ; then
    OCM_API_URL=$(jq -r .ocmApiUrl "$JSON_SECRET_FILE")
    OCM_CLIENT_ID=$(jq -r .ocmClientID "$JSON_SECRET_FILE")
    OCM_CLIENT_SECRET=$(jq -r .ocmClientSecret "$JSON_SECRET_FILE")
    AWS_ACCESS_KEY_ID=$(jq -r .aws_access_key_id "$JSON_SECRET_FILE")
    AWS_SECRET_ACCESS_KEY=$(jq -r .aws_secret_access_key "$JSON_SECRET_FILE")
fi

# OCM credetianl
[ -n "$OCM_API_URL" ] || { echo OCM_API_URL should be defined; exit 1; }
[ -n "$OCM_CLIENT_ID" ] || { echo OCM_CLIENT_ID should be defined; exit 1; }
[ -n "$OCM_CLIENT_SECRET" ] || { echo OCM_CLIENT_SECRET should be defined; exit 1; }
export OCM_API_URL_BASE64=$(echo -n "$OCM_API_URL"|base64)
export OCM_CLIENT_ID_BASE64=$(echo -n "$OCM_CLIENT_ID"|base64)
export OCM_CLIENT_SECRET_BASE64=$(echo -n "$OCM_CLIENT_SECRET"|base64)

# AWS credentials
[ -n "$AWS_ACCESS_KEY_ID" ] || { echo AWS_ACCESS_KEY_ID should be defined; exit 1; }
[ -n "$AWS_SECRET_ACCESS_KEY" ] || { echo AWS_SECRET_ACCESS_KEY should be defined; exit 1; }
# Format credentials in INI format for cluster-scoped secret (CAPA requires this format in capa-system namespace)
export AWS_CREDENTIALS=$(echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
region = $AWS_REGION
" | base64 -w 0
)


TEMPLATE_FILE_SECRETS=$(dirname $0)/secrets-template.yaml
TEMPLATE_FILE_IS=$(dirname $0)/is-template.yaml
TEMPLATE_FILE_ROSA=$(dirname $0)/rosa-template.yaml

mkdir -p "$GEN_OUTPUT"
echo creating: "$GEN_OUTPUT/secrets.yaml"
envsubst  < $TEMPLATE_FILE_SECRETS > "$GEN_OUTPUT/secrets.yaml"
echo creating: "$GEN_OUTPUT/is.yaml"
envsubst  < $TEMPLATE_FILE_IS > "$GEN_OUTPUT/is.yaml"
echo creating: "$GEN_OUTPUT/rosa.yaml"
envsubst  < $TEMPLATE_FILE_ROSA > "$GEN_OUTPUT/rosa.yaml"
