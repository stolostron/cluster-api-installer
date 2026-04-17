#!/bin/bash
set -e
CONTEXT="--context=kind-azure-dev"
docker build -t quay.io/mveber/aro-mockup-proxy:latest .
docker push     quay.io/mveber/aro-mockup-proxy:latest
kubectl $CONTEXT -n capz-system patch deployment aro-mockup-proxy \
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"aro-mockup-proxy","imagePullPolicy":"Always"}]}}}}'
kubectl $CONTEXT -n capz-system rollout restart deployment/aro-mockup-proxy
kubectl $CONTEXT -n capz-system rollout status deployment/aro-mockup-proxy

