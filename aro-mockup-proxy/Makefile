.PHONY: build run clean test deps install

# Build the proxy
build:
	go build -o mockup-proxy main.go async_operations.go config.go

# Run the proxy (default: async enabled)
run: build
	ENABLE_ASYNC_OPS=true PROVISIONING_DELAY=10s POLLING_INTERVAL=5s ./mockup-proxy

# Run without async (fast mode for simple testing)
run-fast: build
	ENABLE_ASYNC_OPS=false ./mockup-proxy

# Install dependencies
deps:
	go mod download
	go mod tidy

# Clean build artifacts and database
clean:
	rm -f mockup-proxy
	rm -f aro-hcp-mock.db

# Reset database only
reset-db:
	rm -f aro-hcp-mock.db
	@echo "Database reset. Will be recreated on next run."

# Run tests
test:
	go test -v ./...

# Install to $GOPATH/bin
install:
	go install

# View database contents
db-inspect:
	@if [ -f aro-hcp-mock.db ]; then \
		sqlite3 aro-hcp-mock.db "SELECT id, resource_type, name, provisioning_state FROM resources;" | column -t -s '|'; \
	else \
		echo "Database does not exist yet. Start the proxy to create it."; \
	fi

# Show database schema
db-schema:
	@if [ -f aro-hcp-mock.db ]; then \
		sqlite3 aro-hcp-mock.db ".schema resources"; \
	else \
		echo "Database does not exist yet. Start the proxy to create it."; \
	fi

# Format code
fmt:
	go fmt ./...

# Lint code
lint:
	golangci-lint run

# Development mode with auto-reload (requires air)
dev:
	air

# Docker build
docker-build:
	docker build -t aro-hcp-mock-proxy:latest .

# Docker run
docker-run:
	docker run -p 8080:8080 -v $(PWD)/data:/data aro-hcp-mock-proxy:latest

help:
	@echo "Available targets:"
	@echo "  build       - Build the proxy binary"
	@echo "  run         - Build and run the proxy"
	@echo "  deps        - Download dependencies"
	@echo "  clean       - Remove build artifacts and database"
	@echo "  reset-db    - Reset the database only"
	@echo "  test        - Run tests"
	@echo "  install     - Install to GOPATH/bin"
	@echo "  db-inspect  - View database contents"
	@echo "  db-schema   - Show database schema"
	@echo "  fmt         - Format code"
	@echo "  lint        - Lint code"
	@echo "  dev         - Run with auto-reload (requires air)"
	@echo "  help        - Show this help"
