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

ROOT_DIR=$(realpath $(dirname "${BASH_SOURCE[0]}")"/../")
CONFIGDIR=config
TMPDIR=tmp

kustomize_project() {
    local project_dir=$1
    local working_dir=$2
    local output_manifest=$3

    rm -rf "${working_dir}/${TMPDIR}"
    mkdir -p "${working_dir}/${TMPDIR}"

    cp -v ${project_dir}/*.yaml "${working_dir}/"
    [ -d "${project_dir}/base" ] &&\
     cp -a "${project_dir}/base" "${working_dir}/"|| \
     echo "WARNING: No base directory found in ${project_dir}/base"

    ${KUSTOMIZE} build --enable-alpha-plugins "${working_dir}" >> ${output_manifest}
}

# Function to build manifests for a given config directory
build_config() {
    local config_dir=$1
    local output_suffix=$2
    local src_resources="${ROOT_DIR}/src/${PROJECT}${output_suffix}.yaml"

    # Our current PWD is $WKDIR/${PROJECT}
    echo "Running from $(pwd)"
    echo "Building manifests for ${config_dir}..."

    # Check if the config directory exists for this project
    if [ ! -d "${ROOT_DIR}/${config_dir}/${PROJECT}" ]; then
        echo "No ${config_dir} directory found for project ${PROJECT} (${ROOT_DIR}/${config_dir}/${PROJECT}), skipping..."
        return 0
    fi

    # Load environment variables if they exist
    [ -f "${ROOT_DIR}/${config_dir}/${PROJECT}/env" ] && . "${ROOT_DIR}/${config_dir}/${PROJECT}/env"

    cat /dev/null > "${src_resources}"
    # Copy overlay configurations
    if [ -z "$KUSTOMIZE_CONFIG_DIRS" ]; then
        PROJECT_KUSTOMIZE_DIR="${ROOT_DIR}/${config_dir}/${PROJECT}"
        PROJECT_KUSTOMIZE_WORKDIR="${WKDIR}/${PROJECT}/${CONFIGDIR}"
        kustomize_project "${PROJECT_KUSTOMIZE_DIR}" "${PROJECT_KUSTOMIZE_WORKDIR}" "${src_resources}"
    else
        for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
            PROJECT_KUSTOMIZE_DIR="${ROOT_DIR}/${config_dir}/${PROJECT}/${subdir}"
            PROJECT_KUSTOMIZE_WORKDIR="${WKDIR}/${PROJECT}/${subdir}/${CONFIGDIR}"
            kustomize_project "${PROJECT_KUSTOMIZE_DIR}" "${PROJECT_KUSTOMIZE_WORKDIR}" "${src_resources}"
        done
    fi

    echo "Completed building manifests for ${config_dir}"
}

# Function to setup and build for a specific config directory
setup_and_build() {
    local config_dir=$1
    local output_suffix=$2

    echo "Setting up build for ${config_dir}..."

    # Always re-clone for clean state (except for first build if SKIP_CLONE=true)
    if [ "$SKIP_CLONE" != true -o "$config_dir" != "$CONFIGDIR" ]; then
        mkdir -p $WKDIR
        rm -rf $WKDIR/$PROJECT
        cd $WKDIR
        git clone --depth=1 --branch="${BRANCH}" "${ORGREPO}/${PROJECT}" "${WKDIR}/${PROJECT}"
    fi

    cd "$WKDIR/$PROJECT"
    git fetch --depth=1 origin "${BRANCH}" && git checkout "${BRANCH}"

    build_config "$config_dir" "$output_suffix"
}


mkdir -p ${ROOT_DIR}/src
export KUSTOMIZE_PLUGIN_HOME="${ROOT_DIR}/kustomize-plugins"

# Build manifests for standard config directory
setup_and_build "config" ""

# Build manifests for config-k8s directory if it exists
if [ -d "${ROOT_DIR}/config-k8s/${PROJECT}" ]; then
    setup_and_build "config-k8s" "-k8s"
else
    echo "WARNING: No config-k8s directory found for project ${PROJECT}, OCP-only chart will be generated"
fi
