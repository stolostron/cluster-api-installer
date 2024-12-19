#!/bin/bash
set -e

if [ -z "$PROJECT" ] ; then
    echo "PROJECT name must be defned ex; cluster-api, cluster-api-providers-aws, cluster-api-providers-azure"
    exit -1
fi
if [ -z "$OCP_VERSION" ]; then
    echo "OCP_VERSION must be defned ex; 4.18"
    exit -1
fi
if [ -z "$BUILTDIR" ]; then
    echo "BUILTDIR must be set"
    exit -1
fi


CHARTDIR=../charts/$PROJECT

if [ "$SYNC2CHARTS" ] ;then
    echo 'sync new output to ' $CHARTDIR
    rm -rf $CHARTDIR/templates/*.yaml
	rm -rf $CHARTDIR/crds/*.yaml
    mv $BUILTDIR/apiextensions*.yaml $CHARTDIR/crds
    mv $BUILTDIR/*.yaml $CHARTDIR/templates
	sed -i -e 's/^\(version|appVersion\): .*/\1: "'"$OCP_VERSION"'"/' $CHARTDIR/Chart.yaml
	sed -i -e 's/^\(    tag: vX.XX\).*/\1v'"$OCP_VERSION"/ "$CHARTDIR/values.yaml"
fi