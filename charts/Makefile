OCP_VERSION ?= v4.18
BRANCH ?= release-4.18
SYNC2CHARTS ?= true
ORGREPO ?= https://github.com/openshift
KUSTOMIZE ?= kustomize

build-cluster-api: PROJECT = cluster-api
build-cluster-api-aws-chart: PROJECT = cluster-api-provider-aws
build-cluster-api-azure-chart: PROJECT = cluster-api-provider-azure

.PHONY: build
build: build-cluster-api-chart build-cluster-api-aws-chart build-cluster-api-azure-chart

.PHONY: build-cluster-api-chart
build-cluster-api-chart:

.PHONY: build-cluster-api-aws-chart
build-cluster-api-aws-chart:
	$(eval BUILTDIR=$(shell KUSTOMIZE=$(KUSTOMIZE) ORGREPO=$(ORGREPO) PROJECT=$(PROJECT) BRANCH=$(BRANCH) ../scripts/build.sh | tail -1))
	OCP_VERSION=$(OCP_VERSION) SYNC2CHARTS=$(SYNC2CHARTS) BUILTDIR=$(BUILTDIR) PROJECT=$(PROJECT) ../scripts/sync2chart.sh
	
.PHONY: build-cluster-api-azure-chart
build-cluster-api-azure-chart: 


.PHONY: release-chart
release-chart: