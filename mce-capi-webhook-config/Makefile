
# Image URL to use all building/pushing image targets
IMG ?= mce-capi-webhook-config:latest

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

build: mce-capi-webhook-config

# Build manager binary
mce-capi-webhook-config: main.go webhook/webhook.go
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

install-cert-manager:
	kubectl apply --validate=false -f https://github.com/jetstack/cert-manager/releases/download/v1.0.2/cert-manager.yaml

