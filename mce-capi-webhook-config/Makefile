
# Image URL to use all building/pushing image targets
IMG_REG ?= quay.io
IMG_REPO ?= stolostron
IMG_NAME ?= mce-capi-webhook-config
IMG_TAG ?= latest
IMG ?= ${IMG_REG}/${IMG_REPO}/${IMG_NAME}:${IMG_TAG}

# ENVTEST_K8S_VERSION refers to the version of kubebuilder assets to be downloaded by envtest binary.
ENVTEST_K8S_VERSION = 1.30
## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)
ENVTEST ?= $(LOCALBIN)/setup-envtest


# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

build: mce-capi-webhook-config

.PHONY: envtest
envtest: $(ENVTEST) ## Download envtest-setup locally if necessary.
$(ENVTEST): $(LOCALBIN)
	GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-runtime/tools/setup-envtest@release-0.17

.PHONY: test
test: envtest ## Run tests.
	OPERATOR_VERSION=9.9.9 KUBEBUILDER_ASSETS="$(shell $(ENVTEST) use $(ENVTEST_K8S_VERSION) -p path)" \
	ENV_TEST="true" go test $(shell go list ./... | grep -E -v "test") -coverprofile cover.out

# Build manager binary
mce-capi-webhook-config: main.go webhook/webhook.go go.mod go.sum
	go build -o mce-capi-webhook-config main.go

# Run against the configured Kubernetes cluster in ~/.kube/config
run: webhook
	go run ./main.go

uninstall:
	kubectl delete -f deployments/

deploy: webhook
	kubectl apply -f deployments/

# Build the docker image
docker-build: webhook
	docker build . -t ${IMG}

# Push the docker image
docker-push:
	docker push ${IMG}

build-deploy-crc: docker-build deploy-crc

deploy-crc:
	docker login -u kubeadmin -p $(shell oc whoami -t) --tls-verify=false default-route-openshift-image-registry.apps-crc.testing
	docker push ${IMG} default-route-openshift-image-registry.apps-crc.testing/mce-capi-webhook-config/mce-capi-webhook-config:latest
	kubectl apply -f deployments/rbac.yaml
	kubectl apply -f deployments/deployment.yaml
	kubectl apply -f deployments/mutatingwebhook.yaml


install-cert-manager:
	kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.0.2/cert-manager.yaml

