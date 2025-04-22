#!/bin/bash
set -e

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


CHARTDIR=../charts/$PROJECT
NEWCHART=$BUILTDIR/new-chart.yml

if [ "$SYNC2CHARTS" ] ;then
    echo 'sync new output to ' $CHARTDIR
    rm -rf $CHARTDIR/templates/*.yaml
    rm -rf $CHARTDIR/crds/*.yaml
    mv $BUILTDIR/apiextensions*.yaml $CHARTDIR/crds
    mv $BUILTDIR/*.yaml $CHARTDIR/templates

    echo "updating versions in:" "$CHARTDIR/Chart.yaml" "$CHARTDIR/values.yaml"
    echo "* chart version: ${CHART_VERSION}"
    echo "* chart app version: ${CHART_APP_VERSION}"
    echo "* chart values image tag: ${CHART_VALUES_IMAGE_TAG}"
    sed -i -e 's/^version: .*/version: "'"${CHART_VERSION}"'"/' "${CHARTDIR}/Chart.yaml"
    sed -i -e 's/^appVersion: .*/appVersion: "'"${CHART_APP_VERSION}"'"/' "${CHARTDIR}/Chart.yaml"
    sed -i -e 's/^\(    tag: \).*/\1'"${CHART_VALUES_IMAGE_TAG_PREFIX}${CHART_VALUES_IMAGE_TAG}"/ "$CHARTDIR/values.yaml"
    
    echo 'Run helm template after sync saving the output to ' $NEWCHART
    $HELM template $CHARTDIR --include-crds | \
      grep -v '^#' > $NEWCHART

    if [ -n "$GITHUB_OUTPUT" ] ; then
        echo "using: GITHUB_OUTPUT=$GITHUB_OUTPUT NEWCHART=$NEWCHART"
        # when started under github workflow
        if [ $(git diff --name-only "$CHARTDIR"|wc -l) -gt 0 ] ; then
            echo "updated_$PROJECT=true" >> "$GITHUB_OUTPUT"
            echo "using: GITHUB_OUTPUT=$GITHUB_OUTPUT updated$PROJECT ... NEWCHART=$NEWCHART"
        fi
    fi
    
    if [ "$SORTED_OUTPUT" == "true" ] ; then
      $YQ ea '[.] | sort_by(.apiVersion,.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' < "$NEWCHART" > "${NEWCHART#.yaml}-sorted.yaml"
    fi
fi
