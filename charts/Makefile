OCP_VERSION ?= 4.19
BRANCH ?= master
SYNC2CHARTS ?= true
ORGREPO ?= https://github.com/openshift
PROJECTS = \
	cluster-api \
	cluster-api-provider-aws \
	cluster-api-provider-openshift-assisted \
	cluster-api-provider-metal3

ifeq ($(filter $(BRANCH), master main),$(BRANCH))
	TAG := latest
else
	TAG := $(patsubst release-%, %,$(BRANCH))
endif
CHART_VERSION = $(OCP_VERSION)
CHART_APP_VERSION = $(OCP_VERSION)
CHART_VALUES_IMAGE_TAG = $(OCP_VERSION)
CHART_VALUES_IMAGE_TAG_PREFIX = "v"

# Define specific overrides
ORGREPO_cluster-api-provider-openshift-assisted = https://github.com/openshift-assisted
KUSTOMIZE_CONFIG_DIRS_cluster-api-provider-openshift-assisted = "bootstrap" "controlplane"
CHART_VERSION_cluster-api-provider-openshift-assisted = "1.0.0"
CHART_APP_VERSION_cluster-api-provider-openshift-assisted = $(TAG)
CHART_VALUES_IMAGE_TAG_cluster-api-provider-openshift-assisted = $(TAG)
CHART_VALUES_IMAGE_TAG_PREFIX_cluster-api-provider-openshift-assisted = ""

BRANCH_cluster-api-provider-metal3 = main
CHART_VALUES_IMAGE_TAG_cluster-api-provider-metal3 = $(TAG)
CHART_VALUES_IMAGE_TAG_PREFIX_cluster-api-provider-metal3 = ""

WKDIR ?= ../out

.PHONY: build-cluster-api-chart build-cluster-api-provider-aws-chart build-cluster-api-provider-azure-chart build-cluster-api-provider-openshift-assisted-chart

# Define the build target for each project
define make-chart-target
build-$(1)-chart:
	@echo "Building $(1) chart"
	WKDIR="$(WKDIR)" \
	ORGREPO="$(if $(ORGREPO_$(1)),$(ORGREPO_$(1)),$(ORGREPO))" \
	KUSTOMIZE_CONFIG_DIRS="$(if $(KUSTOMIZE_CONFIG_DIRS_$(1)),$(KUSTOMIZE_CONFIG_DIRS_$(1)),)" \
	PROJECT="$(1)" \
	BRANCH="$(if $(BRANCH_$(1)),$(BRANCH_$(1)),$(BRANCH))" \
	../scripts/build.sh
	BUILTDIR="$(WKDIR)/$(1)/config/tmp" \
	CHART_VERSION="$(if $(CHART_VERSION_$(1)),$(CHART_VERSION_$(1)),$(CHART_VERSION))" \
	CHART_APP_VERSION="$(if $(CHART_APP_VERSION_$(1)),$(CHART_APP_VERSION_$(1)),$(CHART_APP_VERSION))" \
	CHART_VALUES_IMAGE_TAG="$(if $(CHART_VALUES_IMAGE_TAG_$(1)),$(CHART_VALUES_IMAGE_TAG_$(1)),$(CHART_VALUES_IMAGE_TAG))" \
	CHART_VALUES_IMAGE_TAG_PREFIX="$(if $(CHART_VALUES_IMAGE_TAG_PREFIX_$(1)),$(CHART_VALUES_IMAGE_TAG_PREFIX_$(1)),$(CHART_VALUES_IMAGE_TAG_PREFIX))" \
	SYNC2CHARTS="$(SYNC2CHARTS)" \
	PROJECT="$(1)" \
	../scripts/sync2chart.sh
endef

$(foreach proj,$(PROJECTS),$(eval $(call make-chart-target,$(proj))))

.PHONY: build
build: $(addprefix build-,$(addsuffix -chart, $(PROJECTS)))

.PHONY: test-chart-crc
test-chart-crc:
	# run the deploy script with crc 
	(cd ..; export PROJECT_ONLY=$(PROJECT) ; ./scripts/deploy-charts-crc.sh )

.PHONY: build-cluster-api-azure-chart
build-cluster-api-azure-chart: 

.PHONY: release-chart
release-chart:
