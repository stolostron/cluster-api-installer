#!/bin/bash -e
SCRIPT_DIR=$(dirname "$0")
${YQ} eval 'del(.vars[] | select(.name == "CERTIFICATE_NAME" or .name == "CERTIFICATE_NAMESPACE"))' "${SCRIPT_DIR}/default/kustomization.yaml" > "${SCRIPT_DIR}/default/kustomization.yaml.tmp"
cp "${SCRIPT_DIR}/default/kustomization.yaml.tmp" "${SCRIPT_DIR}/default/kustomization.yaml"