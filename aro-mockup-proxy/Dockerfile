FROM golang:1.27-alpine3.24 AS builder

# Use a toolchain release that includes the Go standard-library security fixes.
ENV GOTOOLCHAIN=go1.27.3

# Install build dependencies
RUN apk upgrade --no-cache && apk add --no-cache gcc musl-dev sqlite-dev

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum* ./
RUN go mod download

# Copy source
COPY . .

# Build with CGO enabled for SQLite
RUN CGO_ENABLED=1 go build -o mockup-proxy *.go

# Runtime image
FROM alpine:3.24

# Install runtime dependencies
RUN apk upgrade --no-cache && apk add --no-cache ca-certificates sqlite-libs sqlite

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/mockup-proxy .

# Create data directory for database
RUN mkdir -p /data

# Expose proxy port
EXPOSE 8443

# Use /data for persistent storage
ENV MOCK_PROXY_DB=/data/aro-hcp-mock.db

CMD ["./mockup-proxy"]
