#!/bin/bash
set -e
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# This script waits for CAPI/CAPZ controllers to be ready
# Can be used standalone or called by other scripts
#
# Usage:
#   ./wait-for-controllers.sh [controller1] [controller2] ...
DO_INIT_KIND=false DO_DEPLOY=false DO_CHECK=true ${SCRIPT_DIR}/deploy-charts.sh $*
