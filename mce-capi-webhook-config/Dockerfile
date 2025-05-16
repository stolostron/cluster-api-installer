# Build the manager binary
FROM registry.ci.openshift.org/stolostron/builder:go1.24-linux AS builder

WORKDIR /workspace
# Copy the Go Modules manifests
COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY main.go main.go
COPY webhook/ webhook/

# Build
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GO111MODULE=on go build -a -o mce-capi-webhook-config main.go

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
WORKDIR /
COPY --from=builder /workspace/mce-capi-webhook-config /
USER nonroot:nonroot

ENTRYPOINT ["/mce-capi-webhook-config"]
