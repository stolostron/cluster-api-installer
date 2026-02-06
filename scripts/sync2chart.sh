#!/bin/bash
set -e

# Determine project root and set as global variable
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_ROOT=$(dirname "$SCRIPT_DIR")

# Helper function to rename invalid filenames
_rename_invalid_filenames() {
    search_dir=$1
    find "${search_dir}" \( -name '*{{*' -o -name '*}}*' -o -name '* *' -o -name '.*' \) -print0 | while IFS= read -r -d $'\0' old_name; do
        dir_name=$(dirname "${old_name}")
        base_name=$(basename "${old_name}")
        # Remove leading dots first, then remove other invalid characters
        new_base_name=$(echo "${base_name}" | sed -E 's/[ {}]//g' | sed -E 's/^\.+//')
        new_name="${dir_name}/${new_base_name}"
        if [[ "${old_name}" != "${new_name}" ]]; then
            mv -iv "${old_name}" "${new_name}"
        fi
    done
}

_create_chart_structure() {
    local chartdir="$1"
    echo "creating chart structure for $chartdir"
    mkdir -p "$chartdir/templates" "$chartdir/crds"
    rm -rf "$chartdir/templates"/*.yaml
    rm -rf "$chartdir/templates"/.*.yaml

    rm -rf "$chartdir/crds"/*.yaml
    rm -rf "$chartdir/crds"/.*.yaml
}

_move_chart_files() {
    local builtdir="$1"
    local chartdir="$2"
    
    echo "syncing chart files for $builtdir -> $chartdir"
    # Sanitize filenames in source directory first
    _rename_invalid_filenames "$builtdir"
    
    # Move CRDs and other resources
    if ls "$builtdir"/apiextensions*.yaml 1> /dev/null 2>&1; then
        mv -v "$builtdir"/apiextensions*.yaml "$chartdir/crds/"
    fi
    if ls "$builtdir"/*.yaml 1> /dev/null 2>&1; then
        mv -v "$builtdir"/*.yaml "$chartdir/templates/"
    fi

}

# Function to sync chart files from built directory to chart directory
sync_chart_files() {
    local builtdir="$1"
    local chartdir="$2"
    local suffix="$3"
    local _chartdir="${chartdir}$suffix"
    local _builtdir="${builtdir%/config/tmp}$suffix/config/tmp"

    [ -d "$_builtdir" ] || return 0
    _create_chart_structure "$_chartdir"
    _move_chart_files "$_builtdir" "$_chartdir"
}

_update_chart_yaml() {
    local chartdir="$1"
    local chart_version="$2"
    local chart_app_version="$3"
    local chart_values_image_tag="$4"
    echo "updating versions in: $chartdir/Chart.yaml $chartdir/values.yaml"
    echo "* chart version: ${chart_version}"
    echo "* chart app version: ${chart_app_version}"
    echo "* chart values image tag: ${chart_values_image_tag}"
    
    sed -i -e 's/^version: .*/version: "'"${chart_version}"'"/' "${chartdir}/Chart.yaml"
    sed -i -e 's/^appVersion: .*/appVersion: "'"${chart_app_version}"'"/' "${chartdir}/Chart.yaml"

    export CHART_TAG="${CHART_VALUES_IMAGE_TAG_PREFIX:-}${chart_values_image_tag}"
    for I in manager bootstrap controlplane ; do
        $YQ e -i '(. | select(has("'$I'")) | .'$I'.image.tag) = env(CHART_TAG)' "$chartdir/values.yaml"
    done
}

# Function to update chart versions
update_chart_versions() {
    local chartdir="$1"
    local chart_version="$2"
    local chart_app_version="$3"
    local chart_values_image_tag="$4"
    local suffix="$5"

   local _chartdir="${chartdir}$suffix"
   [ -d "$_chartdir" ] || return 0
   _update_chart_yaml "$_chartdir" "$chart_version" "$chart_app_version" "$chart_values_image_tag"
   echo "updated chart versions in $_chartdir"
}

# Function to generate helm template output
generate_helm_template() {
    local chartdir="$1"
    local output_file="$2"
    local suffix="$3"

    local _chartdir="${chartdir}$suffix"
    local _output_file="${output_file%.yml}$suffix.yml"
    [ -d "$_chartdir" ] || return 0
    _save_helm_template "$_chartdir" "$_output_file"
    echo "generated helm template output to $_output_file"
}

_save_helm_template() {
    local chartdir="$1"
    local output_file="$2"

    output_dir=$(dirname "$output_file")
    echo "Run helm template after sync saving the output to $output_file"
    $HELM template "$chartdir" --include-crds | grep -v '^#' > "$output_file"
    
    if [ "$SORTED_OUTPUT" == "true" ] ; then
      $YQ ea '[.] | sort_by(.apiVersion,.kind,.metadata.name) | .[] | splitDoc|sort_keys(..)' < "$output_file" > "${output_file%.yaml}-sorted.yaml"
    fi
}

if [ -z "$PROJECT" ] ; then
    echo "PROJECT name must be defined ex; cluster-api, cluster-api-providers-aws, cluster-api-providers-azure"
    exit -1
fi
if [ -z "${CHART_VERSION}" ]; then
    echo "CHART_VERSION must be defined ex; 0.1.0"
    exit -1
fi
if [ -z "${CHART_APP_VERSION}" ]; then
    echo "CHART_APP_VERSION must be defined ex; 0.1.0"
    exit -1
fi
if [ -z "${CHART_VALUES_IMAGE_TAG}" ]; then
    echo "CHART_VALUES_IMAGE_TAG must be defined ex; 0.1.0"
    exit -1
fi
if [ -z "$BUILTDIR" ]; then
    echo "BUILTDIR must be set"
    exit -1
fi


CHARTDIR="$PROJECT_ROOT/charts/$PROJECT"
NEWCHART="$(realpath "$BUILTDIR")/new-chart.yml"

if [ "$SYNC2CHARTS" ] ;then
    for suffix in "" "-k8s" "-kind" ; do
        [ -d "$CHARTDIR$suffix" ] || continue
        sync_chart_files "$BUILTDIR" "$CHARTDIR" "$suffix" 
        update_chart_versions "$CHARTDIR" "$CHART_VERSION" "$CHART_APP_VERSION" "$CHART_VALUES_IMAGE_TAG" "$suffix"
        generate_helm_template "$CHARTDIR" "$NEWCHART" "$suffix"
    done


    IS_UPDATED=false
    if [ $(git diff --name-only -- "$CHARTDIR"{,-k8s,-kind} $SRC_PROJECT_FILE|wc -l) -gt 0 ] ; then
        IS_UPDATED=true
    fi
    echo "updated_$PROJECT=$IS_UPDATED"
    if [ -n "$GITHUB_OUTPUT" ] ; then
        # when started under github workflow
        if [ "$IS_UPDATED" = true ] ; then
            echo "updated_$PROJECT=true" >> "$GITHUB_OUTPUT"
            echo "using: GITHUB_OUTPUT=$GITHUB_OUTPUT updated_$PROJECT ... NEWCHART=$NEWCHART"
        fi
    fi
    
fi
