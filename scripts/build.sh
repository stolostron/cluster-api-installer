#!/bin/bash
set -e

if [ -z "$PROJECT" ] ; then
    echo "PROJECT name must be defned ex; cluster-api, cluster-api-providers-aws, cluster-api-providers-azure"
    exit -1
fi
if [ -z "$BRANCH" ]; then
    echo "BRANCH must be defned ex; master, release-4.18"
    exit -1
fi

WKDIR=../out
CONFIGDIR=config
TMPDIR=tmp


mkdir -p $WKDIR
rm -rf $WKDIR/$PROJECT
mkdir $WKDIR/$PROJECT
git clone https://github.com/openshift/"$PROJECT" $WKDIR/$PROJECT
cp ../$CONFIGDIR/$PROJECT/kustomization.yaml $WKDIR/$PROJECT/$CONFIGDIR

cd $WKDIR/$PROJECT
git checkout "$BRANCH" && git pull
rm -rf $CONFIGDIR/$TMPDIR
mkdir -p $CONFIGDIR/$TMPDIR
kustomize build config -o $CONFIGDIR/$TMPDIR
rm -rf $CONFIGDIR/$TMPDIR/cert*

echo $WKDIR/$PROJECT/$CONFIGDIR/$TMPDIR