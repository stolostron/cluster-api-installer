#!/bin/bash
set -e

# Determine project root and set as global variable
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")

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
    
    # Copy all YAML files
    if ls "${src_dir}"/*.yaml 1> /dev/null 2>&1; then
        cp -v "${src_dir}"/*.yaml "${dst_dir}/"
    fi
    
    # Copy hack.sh file if it exists
    if [ -f "${src_dir}/hack.sh" ]; then
        cp -v "${src_dir}/hack.sh" "${dst_dir}/"
    fi
    
    # Copy base directory if it exists
    if [ -d "${src_dir}/base" ]; then
        cp -av "${src_dir}/base" "${dst_dir}/"
    fi
}

# Function to copy configuration files to the working directory
copy_config() {
    local project=$1
    local config_type=$2
    local project_dir=$3
    
    echo "Copying $config_type configuration for project: $project"
    
    if [ -z "$KUSTOMIZE_CONFIG_DIRS" ]; then
        _copy_config "$PROJECT_ROOT/${config_type}/${project}" "${project_dir}/${CONFIGDIR}"
    else
        for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
            _copy_config "$PROJECT_ROOT/${config_type}/${project}/${subdir}" "${project_dir}/${subdir}/${CONFIGDIR}"
        done
    fi
}

# Helper function to build kustomize resources from a specific config directory
_kustomize_config_build() {
    local config_dir=$1
    local output_file=$2
    local output_dir=$3
    
    echo "Building kustomize resources from $config_dir"
    
    # Build default configuration
    ${KUSTOMIZE} build "${config_dir}/default" >> "$output_file"
    
    # Build with alpha plugins enabled  
    ${KUSTOMIZE} build --enable-alpha-plugins "$config_dir" -o "$output_dir"
    if [ -n "$K_DEBUG" ] ; then
        mkdir -p $(dirname /tmp/kdebug/${output_dir})
        cp -r ${output_dir} /tmp/kdebug/${output_dir}
    fi
}

# Function to build kustomize resources
kustomize_build() {
    local project_dir=$1
    
    echo "Building kustomize resources for project: $project_dir"
    cd $project_dir
    
    # Execute hack.sh if present
    if [ -f "${CONFIGDIR}/hack.sh" ]; then
        echo "Executing hack.sh for project: $project"
        chmod +x "${CONFIGDIR}/hack.sh"
        "${CONFIGDIR}/hack.sh"
    fi

    # Prepare temporary directory using absolute paths
    local tmp_dir="${project_dir}/config/tmp"
    rm -rf "${tmp_dir}"
    mkdir -p "${tmp_dir}"

    cat /dev/null > "${SRC_RESOURCES}"
    if [ -z "${KUSTOMIZE_CONFIG_DIRS}" ]; then
        _kustomize_config_build "config" "${SRC_RESOURCES}" "$tmp_dir"
    else
        # Initialize empty file for appending
        for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
            _kustomize_config_build "${subdir}/config" "${SRC_RESOURCES}" "$tmp_dir"
        done
    fi
}




# Main build function that accepts config type (config or config-k8s)
build_for_config() {
    local config_type=$1
    
    if [ -z "$config_type" ]; then
        echo "config_type must be provided: config or config-k8s"
        exit -1
    fi
    
    # Skip silently if config directory doesn't exist for this project
    if [ ! -d "$PROJECT_ROOT/${config_type}/${PROJECT}" ]; then
        return
    fi
    
    # Change to project root
    cd "$PROJECT_ROOT"
    echo "Changed to project root: $(pwd)"
    
    # Determine output filename suffix by removing "config" from config_type
    local output_suffix="${config_type#config}"

    local project_dir="$WKDIR/$PROJECT$output_suffix"
    
    # Clone or skip clone if already exists
    if [ "$SKIP_CLONE" != true -o ! -d $project_dir ] ; then
        mkdir -p $WKDIR
        rm -rf "$project_dir"
        mkdir "$project_dir"
        git clone --depth=1 --branch="${BRANCH}" "${ORGREPO}/${PROJECT}" "${project_dir}"
    fi

    # Setup environment with config-type specific output file using absolute paths
    mkdir -p "$PROJECT_ROOT/src"
    export SRC_RESOURCES="$PROJECT_ROOT/src/$PROJECT${output_suffix}.yaml"
    export KUSTOMIZE_PLUGIN_HOME="$PROJECT_ROOT/kustomize-plugins"
    [ -f "$PROJECT_ROOT/${config_type}/$PROJECT/env" ] && . "$PROJECT_ROOT/${config_type}/$PROJECT/env"

    # Copy configuration files from the specified config type directory
    copy_config "$PROJECT" "$config_type" "$project_dir" 

    # Fetch latest changes and switch to branch
    cd $project_dir
    git fetch --depth=1 origin "${BRANCH}" && git checkout "${BRANCH}"

    # Build kustomize resources
    kustomize_build "$project_dir"
}

mkdir -p "${WKDIR}"

# Execute build function with config type (default to "config" for backward compatibility)
set -x
build_for_config "config"
if [ -d $PROJECT_ROOT/config-k8s/$PROJECT ]; then
     build_for_config "config-k8s"
fi
