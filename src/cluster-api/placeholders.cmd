ADD:select(.metadata.labels."cluster.x-k8s.io/provider" == "cluster-api").metadata.labels=clusterApiLabels.yaml
REP:select(.kind == "Deployment").spec.template.spec.containers[0].command[0]=manager.command.yaml
ADD:select(.kind == "Deployment").spec.template.spec.containers[0]=manager.resources.yaml
SET:select(.kind == "Deployment").spec.template.spec.containers[0].image=.Values.manager.image.repository:.Values.manager.image.tag
SET:select(.kind == "Deployment").spec.template.spec.containers[0].imagePullPolicy=.Values.manager.image.pullPolicy
ADD:select(.kind == "Deployment").spec.template.spec=priorityClassName.yaml
SET:(.. | select(key == "namespace" and type == "!!str" and . == "capi-system"))|=.Values.namespace
SET:select(.kind == "Namespace" and .metadata.name == "capi-system").metadata.name=.Values.namespace
SET:select(.kind == "Deployment").spec.replicas=.Values.replicaCount
ENV:CAPI_DIAGNOSTICS_ADDRESS=:__.Values.manager.diagnosticsAddress__
ENV:CAPI_INSECURE_DIAGNOSTICS=__.Values.manager.insecureDiagnostics__
ENV:CAPI_USE_DEPRECATED_INFRA_MACHINE_NAMING=__.Values.manager.useDeprecatedInfraMachineNaming__
ENV:EXP_MACHINE_POOL=__.Values.manager.featureGates.machinePool__
ENV:EXP_CLUSTER_RESOURCE_SET=__.Values.manager.featureGates.clusterResourceSet__
ENV:CLUSTER_TOPOLOGY=__.Values.manager.featureGates.clusterTopology__
ENV:EXP_RUNTIME_SDK=__.Values.manager.featureGates.runtimeSDK__
ENV:EXP_MACHINE_SET_PREFLIGHT_CHECKS=__.Values.manager.featureGates.machineSetPreflightChecks__
