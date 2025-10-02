#!/bin/bash
set -e

# Environment variables:
# - PROJECT: Project name (required)
# - CHART_VERSION, CHART_APP_VERSION, CHART_VALUES_IMAGE_TAG: Chart versioning (required)
# - BUILTDIR: Directory containing built manifests (required)
# - SYNC2CHARTS: Enable syncing to existing charts directory (optional)
# - SORTED_OUTPUT: Enable sorted YAML output (optional)
# - HELM, YQ: Tool paths (optional)

if [ -z "$PROJECT" ] ; then
    echo "PROJECT name must be defned ex; cluster-api, cluster-api-providers-aws, cluster-api-providers-azure"
    exit -1
fi
if [ -z "${CHART_VERSION}" ]; then
    echo "CHART_VERSION must be defned ex; 0.1.0"
    exit -1
fi
if [ -z "${CHART_APP_VERSION}" ]; then
    echo "CHART_APP_VERSION must be defned ex; 0.1.0"
    exit -1
fi
if [ -z "${CHART_VALUES_IMAGE_TAG}" ]; then
    echo "CHART_VALUES_IMAGE_TAG must be defned ex; 0.1.0"
    exit -1
fi
if [ -z "$BUILTDIR" ]; then
    echo "BUILTDIR must be set"
    exit -1
fi

ROOT_DIR=$(realpath $(dirname "${BASH_SOURCE[0]}")"/../")

BASE_MANIFEST="${ROOT_DIR}/src/${PROJECT}.yaml"
echo "BASE_MANIFEST=${BASE_MANIFEST}"
[ -f "${BASE_MANIFEST}" ] || (echo "ERROR: missing base manifest for ${PROJECT} (${BASE_MANIFEST})" && exit 123)

K8S_MANIFEST="${ROOT_DIR}/src/${PROJECT}-k8s.yaml"
[ -f "${K8S_MANIFEST}" ] || (echo "WARNING: missing k8s manifest for ${PROJECT} (${K8S_MANIFEST})" && K8S_MANIFEST=${BASE_MANIFEST})

CHARTIFY_OUTPUT_DIR=../chartify-charts/$PROJECT
[ ! -f "$SRC_PROJECT_FILE" ] && SRC_PROJECT_FILE=""


[ -f "$CHARTIFY_OUTPUT_DIR/values.yaml" ] && cp "$CHARTIFY_OUTPUT_DIR"/values.yaml /tmp/values.yaml || touch /tmp/values.yaml
# Clean and create output directory
rm -rf "$CHARTIFY_OUTPUT_DIR"
mkdir -p "$(dirname "$CHARTIFY_OUTPUT_DIR")"

# Run chartify.py
python3 ../scripts/chartify/chartify.py \
    "${K8S_MANIFEST}" \
    "${BASE_MANIFEST}" \
    --condition "global.deployOnOCP" \
    --output "$CHARTIFY_OUTPUT_DIR" \
    --chart-name "$PROJECT" \
    --chart-version "${CHART_VERSION}" \
    --chart-app-version "${CHART_APP_VERSION}" \
    --values-file "/tmp/values.yaml" --debug

IS_UPDATED=false
if [ $(git diff --name-only "$CHARTIFY_OUTPUT_DIR" $BASE_MANIFEST $K8S_MANIFEST|wc -l) -gt 0 ] ; then
    IS_UPDATED=true
fi
echo "updated_$PROJECT=$IS_UPDATED"
if [ -n "$GITHUB_OUTPUT" ] ; then
    # when started under github workflow
    echo "using: GITHUB_OUTPUT=$GITHUB_OUTPUT"
    echo "updated_$PROJECT=$IS_UPDATED" >> "$GITHUB_OUTPUT"
fi

export CHART_TAG="${CHART_VALUES_IMAGE_TAG_PREFIX}${CHART_VALUES_IMAGE_TAG}"
for I in manager bootstrap controlplane ; do
  $YQ e -i '(. | select(has("'$I'")) | .'$I'.image.tag) = env(CHART_TAG)' "$CHARTIFY_OUTPUT_DIR/values.yaml"
done