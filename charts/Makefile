OCP_VERSION ?= 4.18
BRANCH ?= release-4.18
SYNC2CHARTS ?= true
ORGREPO ?= https://github.com/openshift

build-cluster-api-chart: PROJECT = cluster-api
build-cluster-api-aws-chart: PROJECT = cluster-api-provider-aws
build-cluster-api-azure-chart: PROJECT = cluster-api-provider-azure

WKDIR ?= ../out
BUILTDIR=$(WKDIR)/$(PROJECT)/config/tmp

.PHONY: build
build: build-cluster-api-chart build-cluster-api-aws-chart build-cluster-api-azure-chart

.PHONY: build-cluster-api-chart
build-cluster-api-chart:
	WKDIR=$(WKDIR) ORGREPO=$(ORGREPO) PROJECT=$(PROJECT) BRANCH=$(BRANCH) ../scripts/build.sh
	OCP_VERSION=$(OCP_VERSION) SYNC2CHARTS=$(SYNC2CHARTS) BUILTDIR="$(BUILTDIR)" PROJECT=$(PROJECT) ../scripts/sync2chart.sh

.PHONY: build-cluster-api-aws-chart
build-cluster-api-aws-chart:
	WKDIR=$(WKDIR) ORGREPO=$(ORGREPO) PROJECT=$(PROJECT) BRANCH=$(BRANCH) ../scripts/build.sh
	OCP_VERSION=$(OCP_VERSION) SYNC2CHARTS=$(SYNC2CHARTS) BUILTDIR="$(BUILTDIR)" PROJECT=$(PROJECT) ../scripts/sync2chart.sh

.PHONY: test-chart-crc
test-chart-crc:
	# run the deploy script with crc 
	(cd ..; export PROJECT_ONLY=$(PROJECT) ; ./scripts/deploy-charts-crc.sh )
	
.PHONY: build-cluster-api-azure-chart
build-cluster-api-azure-chart: 


.PHONY: release-chart
release-chart:
