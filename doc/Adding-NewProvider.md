# Adding a New Provider
To add a new provider, update the [`charts/Makefile`](https://github.com/stolostron/cluster-api-installer/blob/main/charts/Makefile) and create a Kustomize configuration for the provider.

## Update `Makefile`
You need to create a new target in [`charts/Makefile`](https://github.com/stolostron/cluster-api-installer/blob/main/charts/Makefile), similar to `build-cluster-api-aws-chart` for the AWS provider:
```make
build-cluster-api-aws-chart: PROJECT = cluster-api-provider-aws

 ...

.PHONY: build-cluster-api-aws-chart
build-cluster-api-aws-chart:
        WKDIR=$(WKDIR) ORGREPO=$(ORGREPO) PROJECT=$(PROJECT) BRANCH=$(BRANCH) ../scripts/build.sh
        OCP_VERSION=$(OCP_VERSION) SYNC2CHARTS=$(SYNC2CHARTS) BUILTDIR="$(BUILTDIR)" PROJECT=$(PROJECT) ../scripts/sync2chart.sh
```

Then, add this target (e.g., `build-cluster-api-aws-chart`) as a dependency for the `build` target:
```make
build: build-cluster-api-chart build-cluster-api-aws-chart build-cluster-api-azure-chart
```

### Update Kustomize Configuration
You need to create a `kustomization.yaml` file in the `config/$PROJECT` directory, similar to [`config/cluster-api-provider-aws/kustomization.yaml`](https://github.com/stolostron/cluster-api-installer/blob/main/config/cluster-api-provider-aws/kustomization.yaml) for the AWS provider.

Additionally, you may include an `env` file in the `config/$PROJECT` directory with `<KEY>=<value>` pairs to override default values for variables in source resource templates, like [`config/cluster-api-provider-aws/env`](https://github.com/stolostron/cluster-api-installer/blob/main/config/cluster-api-provider-aws/env) for the AWS provider.

