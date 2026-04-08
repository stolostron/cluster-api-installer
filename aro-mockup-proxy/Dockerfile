FROM golang:1.22-alpine AS builder

# Install build dependencies
RUN apk add --no-cache gcc musl-dev sqlite-dev

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum* ./
RUN go mod download

# Copy source
COPY . .

# Build with CGO enabled for SQLite
RUN CGO_ENABLED=1 go build -o mockup-proxy *.go

# Runtime image
FROM alpine:latest

# Install runtime dependencies
RUN apk add --no-cache ca-certificates sqlite-libs sqlite

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/mockup-proxy .

# Create data directory for database
RUN mkdir -p /data

# Expose proxy port
EXPOSE 8080

# Use /data for persistent storage
ENV MOCK_PROXY_DB=/data/aro-hcp-mock.db

CMD ["./mockup-proxy"]
