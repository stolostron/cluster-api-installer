#!/usr/bin/env bash
set -euo pipefail

readonly api_group="redhatopenshift.azure.com"
from_version=""
to_version=""
apply_changes=false

usage() {
  cat <<'USAGE'
Update CAPZ-managed HCP API versions in every namespace.

Usage:
  doc/migrate-hcp-managed-api-version.sh --from-version VERSION --to-version VERSION [--apply]

Examples:
  doc/migrate-hcp-managed-api-version.sh --from-version v1api20251223preview --to-version v20260901preview
  doc/migrate-hcp-managed-api-version.sh --from-version v20260901preview --to-version v20261001

The default is a server-side dry run. Both versions are required. Pass
--apply to update CAPZ parent resources. CAPZ then reconciles the child HCP
objects, which can trigger normal ASO/ARM reconciliation.
USAGE
}

while (($#)); do
  case "$1" in
    --from-version)
      (($# >= 2)) || { usage >&2; exit 2; }
      from_version="$2"
      shift 2
      ;;
    --to-version)
      (($# >= 2)) || { usage >&2; exit 2; }
      to_version="$2"
      shift 2
      ;;
    --apply)
      apply_changes=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$from_version" || -z "$to_version" ]]; then
  echo 'Both --from-version and --to-version are required.' >&2
  usage >&2
  exit 2
fi

for version in "$from_version" "$to_version"; do
  if [[ ! "$version" =~ ^v[[:alnum:]]+$ ]]; then
    printf 'Invalid API version: %s\n' "$version" >&2
    exit 2
  fi
done

if [[ "$from_version" == "$to_version" ]]; then
  echo 'Source and target API versions must differ.' >&2
  exit 2
fi

for tool in oc jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 2
  fi
done

readonly from_api="${api_group}/${from_version}"
readonly to_api="${api_group}/${to_version}"
readonly parent_resources=(
  aromachinepools.infrastructure.cluster.x-k8s.io
  aroclusters.infrastructure.cluster.x-k8s.io
  arocontrolplanes.controlplane.cluster.x-k8s.io
)
readonly hcp_crds=(
  hcpopenshiftclusters.redhatopenshift.azure.com
  hcpopenshiftclustersnodepools.redhatopenshift.azure.com
  hcpopenshiftclustersexternalauths.redhatopenshift.azure.com
)

for crd in "${hcp_crds[@]}"; do
  if ! oc get crd "$crd" -o json |
    jq -e --arg version "$to_version" \
      'any(.spec.versions[]?; .name == $version and .served == true)' >/dev/null; then
    printf 'Target API %s is not served by CRD %s; no changes made.\n' "$to_version" "$crd" >&2
    exit 1
  fi
done

printf 'Kubernetes context: %s\n' "$(oc config current-context)"
printf 'Mode: %s\n' "$([[ "$apply_changes" == true ]] && echo apply || echo dry-run)"
printf 'HCP API: %s -> %s\n' "$from_api" "$to_api"

# Do not start a bulk migration if any affected cluster lacks the integration
# subnet required by the current API. Handle such legacy clusters separately.
for parent_resource in "${parent_resources[@]}"; do
  parent_json="$(oc get "$parent_resource" -A -o json)"
  unsafe_clusters="$(jq -r --arg from_api "$from_api" '
    .items[] as $parent |
    $parent.spec.resources[]? |
    select(.kind == "HcpOpenShiftCluster" and .apiVersion == $from_api) |
    select((.spec.properties.platform.vnetIntegrationSubnetReference.name // "") == "" and
           (.spec.properties.platform.vnetIntegrationSubnetReference.armId // "") == "") |
    "\($parent.metadata.namespace)/\($parent.metadata.name) embeds HcpOpenShiftCluster/\(.metadata.name) without vnetIntegrationSubnetReference"
  ' <<<"$parent_json")"
  if [[ -n "$unsafe_clusters" ]]; then
    printf 'Cannot bulk-update: an affected HCP cluster has no integration subnet reference.\n%s\nNo CAPZ resources were changed.\n' "$unsafe_clusters" >&2
    exit 1
  fi
done

parents_seen=0
parents_changed=0
for parent_resource in "${parent_resources[@]}"; do
  parent_json="$(oc get "$parent_resource" -A -o json)"

  unexpected_versions="$(jq -r --arg from_api "$from_api" --arg to_api "$to_api" '
    .items[] as $parent |
    $parent.spec.resources[]? |
    select(.kind == "HcpOpenShiftCluster" or
           .kind == "HcpOpenShiftClustersNodePool" or
           .kind == "HcpOpenShiftClustersExternalAuth") |
    select(.apiVersion != $from_api and .apiVersion != $to_api) |
    "\($parent.metadata.namespace)/\($parent.metadata.name): \(.kind)/\(.metadata.name) uses \(.apiVersion)"
  ' <<<"$parent_json")"
  if [[ -n "$unexpected_versions" ]]; then
    printf 'Notice: HCP entries outside the requested source/target versions were left unchanged:\n%s\n' "$unexpected_versions" >&2
  fi

  while IFS= read -r parent; do
    [[ -n "$parent" ]] || continue
    parents_seen=$((parents_seen + 1))

    namespace="$(jq -r '.metadata.namespace' <<<"$parent")"
    name="$(jq -r '.metadata.name' <<<"$parent")"
    hcp_entries="$(jq -r --arg from_api "$from_api" '
      [.spec.resources[]? |
       select(.apiVersion == $from_api and
              (.kind == "HcpOpenShiftCluster" or
               .kind == "HcpOpenShiftClustersNodePool" or
               .kind == "HcpOpenShiftClustersExternalAuth")) |
       "\(.kind)/\(.metadata.name)"] | join(", ")
    ' <<<"$parent")"
    patch="$(jq -c --arg from_api "$from_api" --arg to_api "$to_api" '
      [
        (.spec.resources // [] | to_entries[] |
         select(.value.apiVersion == $from_api and
                (.value.kind == "HcpOpenShiftCluster" or
                 .value.kind == "HcpOpenShiftClustersNodePool" or
                 .value.kind == "HcpOpenShiftClustersExternalAuth")) |
         .key as $index |
         [
           {op:"test", path:("/spec/resources/\($index)/apiVersion"), value:$from_api},
           {op:"replace", path:("/spec/resources/\($index)/apiVersion"), value:$to_api}
         ]) | .[]
      ]
    ' <<<"$parent")"

    printf '%s %s/%s: %s\n' \
      "$([[ "$apply_changes" == true ]] && echo apply || echo dry-run)" \
      "$namespace" "$name" "$hcp_entries"

    if [[ "$apply_changes" == true ]]; then
      oc patch "$parent_resource" -n "$namespace" "$name" \
        --type=json --patch="$patch" >/dev/null
      parents_changed=$((parents_changed + 1))
    else
      oc patch "$parent_resource" -n "$namespace" "$name" \
        --type=json --patch="$patch" --dry-run=server >/dev/null
    fi
  done < <(
    jq -c --arg from_api "$from_api" '
      .items[] |
      select([.spec.resources[]? |
        select(.apiVersion == $from_api and
               (.kind == "HcpOpenShiftCluster" or
                .kind == "HcpOpenShiftClustersNodePool" or
                .kind == "HcpOpenShiftClustersExternalAuth"))] | length > 0)
    ' <<<"$parent_json"
  )
done

if [[ "$parents_seen" == 0 ]]; then
  echo 'No CAPZ-managed HCP entries match the source API version.'
elif [[ "$apply_changes" == true ]]; then
  printf 'Patched %s CAPZ parent resource(s). Wait for reconciliation, then rerun the HCP originalVersion and CRD storedVersions checks in the migration guide.\n' "$parents_changed"
else
  printf 'Dry run validated %s CAPZ parent resource(s). Re-run with --apply to update them.\n' "$parents_seen"
fi
