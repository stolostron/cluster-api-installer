# CAPI Helm Chart Testing Framework Makefile

# Configuration
GO_VERSION ?= 1.21
CLUSTER_NAME ?= capi-test
KUBERNETES_VERSION ?= v1.28.0
CHARTS_PATH ?= ../charts
TIMEOUT ?= 30m
TEST_SUITE ?= installation

# Directories
BIN_DIR := bin
SCRIPTS_DIR := scripts

# Binaries
TEST_RUNNER := $(BIN_DIR)/test-runner

# Test flags
TEST_FLAGS ?= -v
CHART_FILTER ?=
PROVIDER_FILTER ?=

.PHONY: all
all: test

.PHONY: help
help: ## Display this help message
	@echo "CAPI Helm Chart Testing Framework"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: deps
deps: ## Install dependencies
	@echo "Installing Go dependencies..."
	go mod download
	go mod tidy

.PHONY: build
build: deps ## Build test runner binary
	@echo "Building test runner..."
	mkdir -p $(BIN_DIR)
	go build -o $(TEST_RUNNER) ./cmd/test-runner

.PHONY: clean
clean: ## Clean build artifacts
	rm -rf $(BIN_DIR)
	go clean -cache

.PHONY: setup-cluster
setup-cluster: ## Setup minikube cluster for testing
	@echo "Setting up minikube cluster..."
	CLUSTER_NAME=$(CLUSTER_NAME) \
	KUBERNETES_VERSION=$(KUBERNETES_VERSION) \
	$(SCRIPTS_DIR)/setup-minikube.sh setup

.PHONY: cleanup-cluster  
cleanup-cluster: ## Cleanup minikube cluster
	@echo "Cleaning up minikube cluster..."
	CLUSTER_NAME=$(CLUSTER_NAME) \
	$(SCRIPTS_DIR)/setup-minikube.sh cleanup

.PHONY: cluster-status
cluster-status: ## Show cluster status
	CLUSTER_NAME=$(CLUSTER_NAME) \
	$(SCRIPTS_DIR)/setup-minikube.sh status

# Test targets
.PHONY: test
test: test-installation ## Run all tests (default: installation tests)

.PHONY: test-all
test-all: build ## Run complete test suite
	$(TEST_RUNNER) \
		--charts-path=$(CHARTS_PATH) \
		--test-suite=all \
		--timeout=$(TIMEOUT) \
		$(if $(CHART_FILTER),--chart-filter=$(CHART_FILTER)) \
		$(if $(PROVIDER_FILTER),--provider-filter=$(PROVIDER_FILTER))

.PHONY: test-installation
test-installation: build ## Run installation tests
	$(TEST_RUNNER) \
		--charts-path=$(CHARTS_PATH) \
		--test-suite=installation \
		--timeout=$(TIMEOUT) \
		$(if $(CHART_FILTER),--chart-filter=$(CHART_FILTER)) \
		$(if $(PROVIDER_FILTER),--provider-filter=$(PROVIDER_FILTER))

.PHONY: test-upgrade
test-upgrade: build ## Run upgrade tests
	$(TEST_RUNNER) \
		--charts-path=$(CHARTS_PATH) \
		--test-suite=upgrade \
		--timeout=$(TIMEOUT) \
		$(if $(CHART_FILTER),--chart-filter=$(CHART_FILTER)) \
		$(if $(PROVIDER_FILTER),--provider-filter=$(PROVIDER_FILTER))

.PHONY: test-functionality
test-functionality: build ## Run functionality tests
	$(TEST_RUNNER) \
		--charts-path=$(CHARTS_PATH) \
		--test-suite=functionality \
		--timeout=$(TIMEOUT) \
		$(if $(CHART_FILTER),--chart-filter=$(CHART_FILTER)) \
		$(if $(PROVIDER_FILTER),--provider-filter=$(PROVIDER_FILTER))

# Go test targets for CI/IDE integration
.PHONY: go-test
go-test: deps ## Run Go tests directly
	go test $(TEST_FLAGS) ./e2e/... \
		-timeout=$(TIMEOUT) \
		$(if $(CHART_FILTER),-chart-filter=$(CHART_FILTER)) \
		$(if $(PROVIDER_FILTER),-provider-filter=$(PROVIDER_FILTER))

.PHONY: go-test-installation
go-test-installation: deps ## Run Go installation tests
	go test $(TEST_FLAGS) ./e2e/ -run TestChartInstallation \
		-timeout=$(TIMEOUT)

# Chart-specific test targets
.PHONY: test-capi
test-capi: ## Test cluster-api chart
	$(MAKE) test-installation CHART_FILTER=cluster-api

.PHONY: test-capa
test-capa: ## Test cluster-api-provider-aws chart
	$(MAKE) test-installation CHART_FILTER=cluster-api-provider-aws

.PHONY: test-capm3
test-capm3: ## Test cluster-api-provider-metal3 chart
	$(MAKE) test-installation CHART_FILTER=cluster-api-provider-metal3

.PHONY: test-capoa
test-capoa: ## Test cluster-api-provider-openshift-assisted chart
	$(MAKE) test-installation CHART_FILTER=cluster-api-provider-openshift-assisted

# Development targets
.PHONY: lint
lint: ## Run linter
	golangci-lint run ./...

.PHONY: fmt
fmt: ## Format code
	go fmt ./...

.PHONY: vet
vet: ## Run go vet
	go vet ./...

.PHONY: check
check: fmt vet lint ## Run all checks

# CI targets
.PHONY: ci-setup
ci-setup: deps setup-cluster ## Setup for CI environment

.PHONY: ci-test
ci-test: build test-installation ## Run CI tests

.PHONY: ci-cleanup
ci-cleanup: cleanup-cluster ## Cleanup CI environment

# Integration with parent Makefile
.PHONY: test-charts-minikube
test-charts-minikube: ci-setup ci-test ## Integration target for parent Makefile
	@echo "Minikube chart tests completed"

# Development workflow targets
.PHONY: dev-setup
dev-setup: deps build setup-cluster ## Setup development environment

.PHONY: dev-test
dev-test: test-installation ## Quick development test

.PHONY: dev-clean
dev-clean: cleanup-cluster clean ## Clean development environment

# Debug targets
.PHONY: debug-cluster
debug-cluster: ## Debug cluster setup
	@echo "Cluster Information:"
	@echo "  Name: $(CLUSTER_NAME)"
	@echo "  Kubernetes Version: $(KUBERNETES_VERSION)"
	@kubectl cluster-info --context minikube-$(CLUSTER_NAME) || echo "Cluster not accessible"
	@echo ""
	@echo "Pods in all namespaces:"
	@kubectl get pods -A --context minikube-$(CLUSTER_NAME) || echo "Cannot get pods"

.PHONY: debug-helm
debug-helm: ## Debug helm setup
	@echo "Helm version:"
	@helm version || echo "Helm not found"
	@echo ""
	@echo "Helm repositories:"
	@helm repo list || echo "No repositories configured"

# Validation targets
.PHONY: validate-charts
validate-charts: ## Validate chart structure
	@echo "Validating charts in $(CHARTS_PATH)..."
	@for chart in $(CHARTS_PATH)/*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			echo "Validating $$chart"; \
			helm lint "$$chart" || exit 1; \
		fi \
	done

.PHONY: template-charts
template-charts: ## Template all charts
	@echo "Templating charts in $(CHARTS_PATH)..."
	@for chart in $(CHARTS_PATH)/*/; do \
		if [ -f "$$chart/Chart.yaml" ]; then \
			chart_name=$$(basename "$$chart"); \
			echo "Templating $$chart_name"; \
			helm template test "$$chart" --dry-run > /dev/null || exit 1; \
		fi \
	done

# Quick targets for common workflows
.PHONY: quick-test
quick-test: dev-setup dev-test ## Quick setup and test

.PHONY: full-test
full-test: dev-setup test-all ## Full setup and comprehensive test