# cluster-api-installer

## For cluster-api
3. run:
   * `make CAPI_VERSION=4.18 helm-capi` this will do: ```
CAPI_VERSION=4.18 SYNC2CHARTS=true ./build-capi.sh
Updating files: 100% (5540/5540), done.
Switched to branch 'release-4.18'
Your branch is up to date with 'origin/release-4.18'.
Already up to date.
-------------------------
PRJ=cluster-api BRANCH=release-4.18
creating placeholders file: openshift/cluster-api/openshift/core-components.yaml ->  config/cluster-api/base/core-components.yaml
using: USE_OC_CERT=yes
# using kustomize: /home/mveber/projekty/capi/cluster-api-installer/hack/tools/kustomize
copy values file: src/cluster-api/values.yaml ->  out/cluster-api/release-4.18/values.yaml
generated: out/cluster-api/release-4.18/templates/namespace.yaml
generated: out/cluster-api/release-4.18/templates/deployment.yaml
generated: out/cluster-api/release-4.18/templates/crd-*
generated: out/cluster-api/release-4.18/templates/service.yaml
generated: out/cluster-api/release-4.18/templates/webhookValidation.yaml
generated: out/cluster-api/release-4.18/templates/roles.yaml
syncing: out/cluster-api/release-4.18/values.yaml out/cluster-api/release-4.18/templates -> charts/cluster-api
```
