OCP_VERSION ?= 4.21
MCE_VERSION ?= 2.11.0-1
SYNC2CHARTS ?= true

DEFAULT_BRANCH ?= release-4.21
CAPA_BRANCH ?= backplane-2.11
DEFAULT_ORGREPO ?= https://github.com/openshift
STOLOSTRON_ORGREPO ?= https://github.com/stolostron
# needs overridable branch, as the non-master branch will differ
OPENSHIFT_ASSISTED_BRANCH ?= backplane-2.11
METAL3_BRANCH ?= release-4.21

OPENSHIFT_ASSISTED_ORGREPO ?= https://github.com/openshift-assisted

get-tag-from-branch = \
	$(strip $(if $(filter $(1),master main),latest, \
	$(if $(findstring release-,$(1)),$(patsubst release-%,%,$(1)), \
		$(if $(findstring backplane-,$(1)),$(patsubst backplane-%,%,$(1)),$(1)))))

get-version-from-branch = \
	$(strip $(if $(filter $(1),master main),"0.0.0-dev", \
	$(if $(findstring release-,$(1)),$(patsubst release-%,%,$(1)), \
		$(if $(findstring backplane-,$(1)),$(patsubst backplane-%,%,$(1)),$(1)))))

WKDIR ?= ../out

.PHONY: build-cluster-api-chart
build-cluster-api-chart:
	@echo "Building cluster-api chart"
	WKDIR="$(WKDIR)" \
	ORGREPO="$(DEFAULT_ORGREPO)" \
	PROJECT="cluster-api" \
	BRANCH="$(DEFAULT_BRANCH)" \
	../scripts/build.sh
	BUILTDIR="$(WKDIR)/cluster-api/config/tmp" \
	CHART_VERSION="$(OCP_VERSION)" \
	CHART_APP_VERSION="$(OCP_VERSION)" \
	CHART_VALUES_IMAGE_TAG="$(OCP_VERSION)" \
	CHART_VALUES_IMAGE_TAG_PREFIX="v" \
	SYNC2CHARTS="$(SYNC2CHARTS)" \
	PROJECT="cluster-api" \
	../scripts/sync2chart.sh

.PHONY: build-cluster-api-provider-aws-chart
build-cluster-api-provider-aws-chart:
	@echo "Building cluster-api-provider-aws chart"
	WKDIR="$(WKDIR)" \
	ORGREPO="$(STOLOSTRON_ORGREPO)" \
	PROJECT="cluster-api-provider-aws" \
	BRANCH="$(CAPA_BRANCH)" \
	../scripts/build.sh
	BUILTDIR="$(WKDIR)/cluster-api-provider-aws/config/tmp" \
	CHART_VERSION="$(MCE_VERSION)" \
	CHART_APP_VERSION="$(MCE_VERSION)" \
	CHART_VALUES_IMAGE_TAG="$(MCE_VERSION)" \
	CHART_VALUES_IMAGE_TAG_PREFIX="" \
	SYNC2CHARTS="$(SYNC2CHARTS)" \
	PROJECT="cluster-api-provider-aws" \
	../scripts/sync2chart.sh

.PHONY: build-cluster-api-provider-openshift-assisted-chart
build-cluster-api-provider-openshift-assisted-chart:
	$(eval TAG=$(call get-tag-from-branch, $(OPENSHIFT_ASSISTED_BRANCH)))
	$(eval VERSION=$(call get-version-from-branch, $(OPENSHIFT_ASSISTED_BRANCH)))
	@echo "Building cluster-api-provider-openshift-assisted-chart"
	WKDIR="$(WKDIR)" \
	ORGREPO="$(OPENSHIFT_ASSISTED_ORGREPO)" \
	KUSTOMIZE_CONFIG_DIRS="bootstrap controlplane" \
	PROJECT="cluster-api-provider-openshift-assisted" \
	BRANCH="$(OPENSHIFT_ASSISTED_BRANCH)" \
	../scripts/build.sh
	BUILTDIR="$(WKDIR)/cluster-api-provider-openshift-assisted/config/tmp" \
	CHART_VERSION="$(VERSION)" \
	CHART_APP_VERSION="$(VERSION)" \
	CHART_VALUES_IMAGE_TAG="$(TAG)" \
	CHART_VALUES_IMAGE_TAG_PREFIX="" \
	SYNC2CHARTS="$(SYNC2CHARTS)" \
	PROJECT="cluster-api-provider-openshift-assisted" \
	../scripts/sync2chart.sh

.PHONY: build-cluster-api-provider-metal3-chart
build-cluster-api-provider-metal3-chart:
	$(eval TAG=$(call get-tag-from-branch, $(METAL3_BRANCH)))
	@echo "Building cluster-api-provider-metal3 chart"
	WKDIR="$(WKDIR)" \
	ORGREPO="$(DEFAULT_ORGREPO)" \
	PROJECT="cluster-api-provider-metal3" \
	BRANCH="$(METAL3_BRANCH)" \
	../scripts/build.sh
	BUILTDIR="$(WKDIR)/cluster-api-provider-metal3/config/tmp" \
	CHART_VERSION="$(OCP_VERSION)" \
	CHART_APP_VERSION="$(OCP_VERSION)" \
	CHART_VALUES_IMAGE_TAG="$(TAG)" \
	CHART_VALUES_IMAGE_TAG_PREFIX="v" \
	SYNC2CHARTS="$(SYNC2CHARTS)" \
	PROJECT="cluster-api-provider-metal3" \
	../scripts/sync2chart.sh

.PHONY: build
build: build-cluster-api-chart build-cluster-api-provider-aws-chart build-cluster-api-azure-chart build-cluster-api-provider-metal3-chart build-cluster-api-provider-openshift-assisted-chart

.PHONY: test-chart-crc
test-chart-crc:
	# run the deploy script with crc 
	(cd ..; export PROJECT_ONLY=$(PROJECT) ; ./scripts/deploy-charts-crc.sh )

.PHONY: build-cluster-api-azure-chart
build-cluster-api-azure-chart: 

.PHONY: release-chart
release-chart:
