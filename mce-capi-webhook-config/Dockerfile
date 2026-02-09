# Build the manager binary
FROM registry.access.redhat.com/ubi9/go-toolset:9.7-1770596585 AS builder

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
ENV GOFLAGS="-tags=strictfipsruntime"
RUN go mod download

# Copy the go source
COPY main.go main.go
COPY webhook/ webhook/

# Build
RUN CGO_ENABLED=1 GO111MODULE=on GOEXPERIMENT=strictfipsruntime go build -a -o /tmp/mce-capi-webhook-config main.go

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

LABEL com.redhat.component="" \
      cpe="cpe:/a:redhat:multicluster_engine:2.9::el9" \
      description="Auto-labeling CAPI resources based on openshift and hypershift namespaces" \
      io.k8s.description="Auto-labeling CAPI resources based on namespaces" \
      io.k8s.display-name="MultiCluster Engine CAPI Webhook Config" \
      io.openshift.tags="cluster-api,capi,multicluster-engine" \
      name="multicluster-engine/mce-capi-webhook-config-rhel9" \
      summary="Auto-labeling CAPI resources based on namespaces"

WORKDIR /
COPY --from=builder /tmp/mce-capi-webhook-config /
USER nonroot:nonroot

ENTRYPOINT ["/mce-capi-webhook-config"]
