#!/bin/bash
set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-aso2}

${SCRIPT_DIR}/setup-kind-cluster.sh "$KIND_CLUSTER_NAME"
export USE_K8S=true
DO_INIT_KIND=false DO_DEPLOY=true DO_CHECK=false ${SCRIPT_DIR}/deploy-charts.sh cluster-api cluster-api-provider-azure
${SCRIPT_DIR}/wait-for-controllers.sh cluster-api cluster-api-provider-azure


