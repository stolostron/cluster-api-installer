#!/bin/bash
set -e

if [ -z "$WKDIR" ]; then
    echo "WKDIR must be provided ex; ../out"
    exit -1
fi
if [ -z "$ORGREPO" ]; then
    echo "ORGREPO must be provided ex; https://github.com/openshift"
    exit -1
fi
if [ -z "$PROJECT" ] ; then
    echo "PROJECT name must be provided ex; cluster-api, cluster-api-providers-aws, cluster-api-providers-azure"
    exit -1
fi
if [ -z "$BRANCH" ]; then
    echo "BRANCH must be provided ex; master, release-4.18"
    exit -1
fi
if [ -z "$KUSTOMIZE" ] ; then
    echo "kustomize command ref must be set"
    exit -1
fi

CONFIGDIR=config
TMPDIR=tmp

if [ "$SKIP_CLONE" != true -o ! -d $WKDIR/$PROJECT ] ; then
    mkdir -p $WKDIR
    rm -rf $WKDIR/$PROJECT
    mkdir $WKDIR/$PROJECT
    git clone --depth=1 --branch="${BRANCH}" "${ORGREPO}/${PROJECT}" "${WKDIR}/${PROJECT}"
fi

mkdir -p ../src
export SRC_RESOURCES=$(realpath ../src/$PROJECT.yaml)
export KUSTOMIZE_PLUGIN_HOME=$(realpath ../kustomize-plugins)
[ -f ../$CONFIGDIR/$PROJECT/env ] && . ../$CONFIGDIR/$PROJECT/env

if [ -z "$KUSTOMIZE_CONFIG_DIRS" ]; then
  cp "../${CONFIGDIR}/${PROJECT}/kustomization.yaml" "${WKDIR}/${PROJECT}/${CONFIGDIR}"
  [ -d ../${CONFIGDIR}/${PROJECT}/base ] && cp -a ../${CONFIGDIR}/${PROJECT}/base "${WKDIR}/${PROJECT}/${CONFIGDIR}"
else
  for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
    cp ."./${CONFIGDIR}/${PROJECT}/${subdir}/kustomization.yaml" "${WKDIR}/${PROJECT}/${subdir}/${CONFIGDIR}"
    [ -d "../${CONFIGDIR}/${PROJECT}/${subdir}/base" ] && \
     cp -a "../${CONFIGDIR}/${PROJECT}/${subdir}/base" "${WKDIR}/${PROJECT}/${subdir}/${CONFIGDIR}" || \
     echo "WARNING: No base directory found in ${CONFIGDIR}/${PROJECT}/${subdir}/base"
  done
fi

cd $WKDIR/$PROJECT
git fetch --depth=1 origin "${BRANCH}" && git checkout "${BRANCH}"
rm -rf $CONFIGDIR/$TMPDIR
mkdir -p $CONFIGDIR/$TMPDIR

if [ -z "${KUSTOMIZE_CONFIG_DIRS}" ]; then
  ${KUSTOMIZE} build config/default > "${SRC_RESOURCES}"
  # do the replacements
  ${KUSTOMIZE} build --enable-alpha-plugins config -o "${CONFIGDIR}/${TMPDIR}"
else
  cat /dev/null > "${SRC_RESOURCES}"
  for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
      ${KUSTOMIZE} build "${subdir}/config/default" >> "${SRC_RESOURCES}"
      # do the replacements
      ${KUSTOMIZE} build --enable-alpha-plugins "${subdir}/config" -o "${CONFIGDIR}/${TMPDIR}"
  done
fi
rm -rf $CONFIGDIR/$TMPDIR/cert*
if [ "$PROJECT" == "cluster-api" ] ; then
    rm -rf $CONFIGDIR/$TMPDIR/apiextensions.k8s.io_v1_customresourcedefinition_ip*.yaml
fi
