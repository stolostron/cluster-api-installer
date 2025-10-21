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
    
    echo "Copying $config_type configuration for project: $project"
    
    if [ -z "$KUSTOMIZE_CONFIG_DIRS" ]; then
        _copy_config "$PROJECT_ROOT/${config_type}/${project}" "${WKDIR}/${project}/${CONFIGDIR}"
    else
        for subdir in ${KUSTOMIZE_CONFIG_DIRS}; do
            _copy_config "$PROJECT_ROOT/${config_type}/${project}/${subdir}" "${WKDIR}/${project}/${subdir}/${CONFIGDIR}"
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
    mkdir -p $(dirname /tmp/kdebug/${output_dir})
    cp -r ${output_dir} /tmp/kdebug/${output_dir}
}

# Function to build kustomize resources
kustomize_build() {
    local project=$1
    local output_suffix=$2
    
    echo "Building kustomize resources for project: $project ($output_suffix)"
    cd $WKDIR/$project
    
    # Execute hack.sh if present
    if [ -f "${CONFIGDIR}/hack.sh" ]; then
        echo "Executing hack.sh for project: $project"
        chmod +x "${CONFIGDIR}/hack.sh"
        "${CONFIGDIR}/hack.sh"
    fi

    # Prepare temporary directory using absolute paths
    local tmp_dir="${WKDIR}/${PROJECT}/config/tmp${output_suffix}"
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



_backup_built_dir() {
    local config_type=$1
    local tmp_output_dir=$2
    output_suffix=${config_type#config}

    target_dir=$tmp_output_dir/config/tmp${output_suffix}
    mkdir -p $target_dir
    cp -r $WKDIR/$PROJECT/config/tmp${output_suffix} $target_dir
}

_restore_built_dir() {
    local config_type=$2
    local tmp_output_dir=$1
    output_suffix=${config_type#config}
    cp -r $tmp_output_dir/config/tmp${output_suffix} $WKDIR/$PROJECT/config/tmp${output_suffix}
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
    
    # Clone or skip clone if already exists
    if [ "$SKIP_CLONE" != true -o ! -d $WKDIR/$PROJECT ] ; then
        mkdir -p $WKDIR
        rm -rf $WKDIR/$PROJECT
        mkdir $WKDIR/$PROJECT
        git clone --depth=1 --branch="${BRANCH}" "${ORGREPO}/${PROJECT}" "${WKDIR}/${PROJECT}"
    fi

    # Setup environment with config-type specific output file using absolute paths
    mkdir -p "$PROJECT_ROOT/src"
    export SRC_RESOURCES="$PROJECT_ROOT/src/$PROJECT${output_suffix}.yaml"
    export KUSTOMIZE_PLUGIN_HOME="$PROJECT_ROOT/kustomize-plugins"
    [ -f "$PROJECT_ROOT/${config_type}/$PROJECT/env" ] && . "$PROJECT_ROOT/${config_type}/$PROJECT/env"

    # Copy configuration files from the specified config type directory
    copy_config "$PROJECT" "$config_type"

    # Fetch latest changes and switch to branch
    cd $WKDIR/$PROJECT
    git fetch --depth=1 origin "${BRANCH}" && git checkout "${BRANCH}"

    # Build kustomize resources
    kustomize_build "$PROJECT" "${output_suffix}"
}

mkdir -p "${WKDIR}"
tmp_output_dir=$(mktemp -d -p ${WKDIR})

# Execute build function with config type (default to "config" for backward compatibility)
build_for_config "config"
# backing up as build_for_config will clear tmp dir
_backup_built_dir "config" "${tmp_output_dir}"
if [ -d $PROJECT_ROOT/config-k8s/$PROJECT ]; then
     build_for_config "config-k8s"
fi

_restore_built_dir "${tmp_output_dir}" "config"

# Clean up temporary directory
rm -rf $tmp_output_dir
