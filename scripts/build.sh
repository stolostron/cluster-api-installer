#!/bin/bash
set -ex

# Validate required environment variables
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
WKDIR=$(realpath $WKDIR)

# Helper function to copy configuration files from source to destination directory
_copy_config() {
    local src_dir=$1
    local dst_dir=$2
    
    # Copy kustomization.yaml file
    if [ -f "${src_dir}/kustomization.yaml" ]; then
        cp -v "${src_dir}/kustomization.yaml" "${dst_dir}/"
    fi
    
    # Copy base directory if it exists
    if [ -d "${src_dir}/base" ]; then
        cp -av "${src_dir}/base" "${dst_dir}/"
    fi
}

# Function to copy configuration files to the working directory
copy_config() {
    local project=$1
    
    echo "Copying configuration for project: $project"
    
    if [ -z "$KUSTOMIZE_CONFIG_DIRS" ]; then
        _copy_config "../${CONFIGDIR}/${project}" "${WKDIR}/${project}/${CONFIGDIR}"
    else
        for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
            _copy_config "../${CONFIGDIR}/${project}/${subdir}" "${WKDIR}/${project}/${subdir}/${CONFIGDIR}"
        done
    fi
}

# Helper function to build kustomize resources from a specific config directory
_kustomize_build() {
    local config_dir=$1
    local output_file=$2
    local output_dir=$3
    
    echo "Building kustomize resources from $config_dir"
    
    # Build default configuration
    ${KUSTOMIZE} build "${config_dir}/default" >> "$output_file"
    
    # Build with alpha plugins enabled  
    ${KUSTOMIZE} build --enable-alpha-plugins "$config_dir" -o "$output_dir"
}

# Function to build kustomize resources
kustomize_build() {
    local project=$1
    
    echo "Building kustomize resources for project: $project"
    cd $WKDIR/$project
    
    # Prepare temporary directory
    rm -rf $CONFIGDIR/$TMPDIR
    mkdir -p $CONFIGDIR/$TMPDIR
    cat /dev/null > "${SRC_RESOURCES}"
    if [ -z "${KUSTOMIZE_CONFIG_DIRS}" ]; then
        _kustomize_build "config" "${SRC_RESOURCES}" "${CONFIGDIR}/${TMPDIR}"
    else
        # Initialize empty file for appending
        for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
            _kustomize_build "${subdir}/config" "${SRC_RESOURCES}" "${CONFIGDIR}/${TMPDIR}"
        done
    fi
}

# Function to cleanup generated files
cleanup() {
    local project=$1
    
    echo "Cleaning up for project: $project"
    cd $WKDIR/$project
    
    # Remove certificate files
    rm -rf $CONFIGDIR/$TMPDIR/cert*
    
    # Project-specific cleanup
    if [ "$project" == "cluster-api" ] ; then
        rm -rf $CONFIGDIR/$TMPDIR/apiextensions.k8s.io_v1_customresourcedefinition_ip*.yaml
    fi
}

# Main execution logic
main() {
    # Clone or skip clone if already exists
    if [ "$SKIP_CLONE" != true -o ! -d $WKDIR/$PROJECT ] ; then
        mkdir -p $WKDIR
        rm -rf $WKDIR/$PROJECT
        mkdir $WKDIR/$PROJECT
        git clone --depth=1 --branch="${BRANCH}" "${ORGREPO}/${PROJECT}" "${WKDIR}/${PROJECT}"
    fi

    # Setup environment
    mkdir -p ../src
    export SRC_RESOURCES=$(realpath ../src/$PROJECT.yaml)
    export KUSTOMIZE_PLUGIN_HOME=$(realpath ../kustomize-plugins)
    [ -f ../$CONFIGDIR/$PROJECT/env ] && . ../$CONFIGDIR/$PROJECT/env

    # Copy configuration files
    copy_config "$PROJECT"

    # Fetch latest changes and switch to branch
    cd $WKDIR/$PROJECT
    git fetch --depth=1 origin "${BRANCH}" && git checkout "${BRANCH}"

    # Build kustomize resources
    kustomize_build "$PROJECT"

    # Cleanup generated files
    cleanup "$PROJECT"
}

# Execute main function
main
