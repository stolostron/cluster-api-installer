#!/bin/bash
set -e
docker build -t quay.io/mveber/aro-mockup-proxy:latest .
docker push     quay.io/mveber/aro-mockup-proxy:latest
kubectl --context=kind-capz-null -n capz-system rollout restart deployment/aro-mockup-proxy
kubectl --context=kind-capz-null -n capz-system rollout status deployment/aro-mockup-proxy

