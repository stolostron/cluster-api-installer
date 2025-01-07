#
# Directories.
#
# Full directory of where the Makefile resides
TOOLS_DIR := hack/tools
TOOLS_BIN_DIR := $(abspath $(TOOLS_DIR)/$(BIN_DIR))
GO_INSTALL := ./scripts/go_install.sh
#
# Binaries.
#
# Note: Need to use abspath so we can invoke these from subdirectories
KUSTOMIZE_VER := v5.3.0
KUSTOMIZE_BIN := kustomize
KUSTOMIZE := $(abspath $(TOOLS_BIN_DIR)/$(KUSTOMIZE_BIN)-$(KUSTOMIZE_VER))
KUSTOMIZE_PKG := sigs.k8s.io/kustomize/kustomize/v5

.PHONY: all
all: build-helm-charts
YQ_VER := v4.35.2
YQ_BIN := yq
YQ :=  $(abspath $(TOOLS_BIN_DIR)/$(YQ_BIN)-$(YQ_VER))
YQ_PKG := github.com/mikefarah/yq/v4

HELM_VER := v3.16.4
HELM_BIN := helm
HELM :=  $(abspath $(TOOLS_BIN_DIR)/$(HELM_BIN))
HELM_PLATFORM := linux-amd64

CLUSTERCTL_VER := v1.9.3
CLUSTERCTL_BIN := clusterctl
CLUSTERCTL := $(abspath $(TOOLS_BIN_DIR)/$(CLUSTERCTL_BIN))
CLUSTERCTL_PLATFORM := linux-amd64

build-helm-charts: $(YQ) $(KUSTOMIZE) $(CLUSTERCTL) $(HELM)
	(export YQ=$(YQ) CLUSTERCTL=$(CLUSTERCTL) KUSTOMIZE=$(KUSTOMIZE) HELM=$(HELM); $(MAKE) -C ./charts build)

.PHONY: test-charts-crc
test-charts-crc:
	$(MAKE) -C ./charts test-chart-crc

$(KUSTOMIZE): # Build kustomize from tools folder.
	CGO_ENABLED=0 GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) $(KUSTOMIZE_PKG) $(KUSTOMIZE_BIN) $(KUSTOMIZE_VER)
$(YQ):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) $(YQ_PKG) $(YQ_BIN) ${YQ_VER}
$(HELM):
	curl -L https://get.helm.sh/helm-$(HELM_VER)-$(HELM_PLATFORM).tar.gz -o $(HELM).tgz
	tar xzf $(HELM).tgz --strip-components=1 -C $(TOOLS_BIN_DIR) $(HELM_PLATFORM)/helm
	rm $(HELM).tgz
$(CLUSTERCTL):
	curl -L https://github.com/kubernetes-sigs/cluster-api/releases/download/$(CLUSTERCTL_VER)/clusterctl-$(CLUSTERCTL_PLATFORM) -o $(CLUSTERCTL)
	chmod a+x $(CLUSTERCTL)
