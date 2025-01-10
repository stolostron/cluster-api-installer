#!/bin/bash
set -e
[ "$CRC_DELETE" == "true" ] && crc delete --force
crc start > /dev/null
export KUBECONFIG=$HOME/.crc/machines/crc/kubeconfig
echo KUBECONFIG=$KUBECONFIG
for CHART in charts/*; do
    [ -f $CHART/Chart.yaml ] || continue
    PROJECT=${CHART#charts/}
    [ -z "$PROJECT_ONLY" -o "$PROJECT_ONLY" == "$PROJECT" ] || continue
    echo ========= deploy: $CHART
    helm template $CHART --include-crds|kubectl apply -f -
    echo
done
echo;echo

for T in capi capa; do
    PROJECT="cluster-api"
    case "$T" in
      capa)
        PROJECT="$PROJECT-provider-aws"
        ;;
      capz)
        PROJECT="$PROJECT-provider-azure"
        ;;
    esac
    [ -z "$PROJECT_ONLY" -o "$PROJECT_ONLY" == "$PROJECT" ] || continue
    echo "Waiting for ${T} controller:"
    kubectl events -n ${T}-system --watch &
    CH_PID=$!
    kubectl -n ${T}-system wait deployment/${T}-controller-manager --for condition=Available=True  --timeout=10m
    kill $CH_PID
    echo
done


