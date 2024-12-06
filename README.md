# cluster-api-installer

## For cluster-api
1. required ../cluster-api-ocp
2. see: `src/cluster-api/placeholders.cmd` ... commands to inplace placeholders:
3. run:
   * `./build-capi.sh` this will do: ```
 ./build-capi.sh 
-------------------------
PRJ=cluster-api VERSION=ocp-4.18
creating placeholders file: ../cluster-api-ocp/openshift/core-components.yaml ->  out/cluster-api/ocp-4.18/placeholders/core-components.yaml
copy values file: src/cluster-api/values.yaml ->  out/cluster-api/ocp-4.18/values.yaml
generated: out/cluster-api/ocp-4.18/templates/deployment.yaml
using: USE_OC_CERT=yes
generated: out/cluster-api/ocp-4.18/templates/capi-crd.yaml
generated: out/cluster-api/ocp-4.18/templates/service.yaml
using: USE_OC_CERT=yes
generated: out/cluster-api/ocp-4.18/templates/webhookValidation.yaml
generated: out/cluster-api/ocp-4.18/templates/roles.yaml
```
   * or `SYNC2CHARTS=true ./build-capi.sh` ... this will update `charts/cluster-api/**` and tru to generate the file `/tmp/x.yaml`
