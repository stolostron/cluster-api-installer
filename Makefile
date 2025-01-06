OCP_VERSION := 4.18
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
all: build-helm-charts helm-capi
YQ_VER := v4.35.2
YQ_BIN := yq
YQ :=  $(abspath $(TOOLS_BIN_DIR)/$(YQ_BIN)-$(YQ_VER))
YQ_PKG := github.com/mikefarah/yq/v4

.PHONY: $(KUSTOMIZE_BIN)
$(KUSTOMIZE_BIN): $(KUSTOMIZE) ## Build a local copy of kustomize.

.PHONY: $(YQ_BIN)
$(YQ_BIN): $(YQ) ## Build a local copy of yq

build-helm-charts: $(KUSTOMIZE)
	$(MAKE) -C ./charts KUSTOMIZE=$(KUSTOMIZE) build

.PHONY: helm-capi
helm-capi: $(YQ) $(KUSTOMIZE) ## Build a local copy of kustomize.
	OCP_VERSION=$(OCP_VERSION) SYNC2CHARTS=true ./build-capi.sh

$(KUSTOMIZE): # Build kustomize from tools folder.
	CGO_ENABLED=0 GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) $(KUSTOMIZE_PKG) $(KUSTOMIZE_BIN) $(KUSTOMIZE_VER)
$(YQ):
	GOBIN=$(TOOLS_BIN_DIR) $(GO_INSTALL) $(YQ_PKG) $(YQ_BIN) ${YQ_VER}

