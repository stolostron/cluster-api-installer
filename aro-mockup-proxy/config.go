package main

import (
	"os"
	"strconv"
	"time"
)

// Config holds configuration for the mock proxy
type Config struct {
	// Server configuration
	Port          string
	ExternalHost  string // hostname for async operation URLs (e.g. service FQDN)
	DatabasePath  string
	AzureEndpoint string
	EnableTLS     bool
	CertFile      string
	KeyFile       string

	// Feature flags
	EnableAsyncOperations bool
	EnableValidation      bool
	EnableMetrics         bool

	// Behavior configuration
	ProvisioningDelay    time.Duration
	DefaultProvisioningState string
	SimulateFailures     bool
	FailureRate          float64

	// Async operation configuration
	AsyncOperationTimeout time.Duration
	PollingInterval       time.Duration

	// Dev environment proxy: when set, hcpOpenShiftCluster requests are
	// forwarded to this endpoint (e.g. "https://localhost:8443" via
	// oc port-forward -n aro-hcp svc/aro-hcp-frontend 8443:8443)
	// instead of being handled by the local SQLite mock.
	DevEndpoint string
}

// LoadConfig loads configuration from environment variables
func LoadConfig() *Config {
	return &Config{
		Port:                     getEnv("MOCK_PROXY_PORT", "172.17.0.1:8443"),
		ExternalHost:             getEnv("MOCK_PROXY_EXTERNAL_HOST", ""),
		DatabasePath:             getEnv("MOCK_PROXY_DB", "./aro-hcp-mock.db"),
		AzureEndpoint:            getEnv("AZURE_ENDPOINT", "https://management.azure.com"),
		EnableTLS:                getEnvBool("ENABLE_TLS", true),
		CertFile:                 getEnv("TLS_CERT_FILE", "./server.crt"),
		KeyFile:                  getEnv("TLS_KEY_FILE", "./server.key"),
		EnableAsyncOperations:    getEnvBool("ENABLE_ASYNC_OPS", true),
		EnableValidation:         getEnvBool("ENABLE_VALIDATION", false),
		EnableMetrics:            getEnvBool("ENABLE_METRICS", false),
		ProvisioningDelay:        getEnvDuration("PROVISIONING_DELAY", 10*time.Second),
		DefaultProvisioningState: getEnv("DEFAULT_PROVISIONING_STATE", "Succeeded"),
		SimulateFailures:         getEnvBool("SIMULATE_FAILURES", false),
		FailureRate:              getEnvFloat("FAILURE_RATE", 0.0),
		AsyncOperationTimeout:    getEnvDuration("ASYNC_TIMEOUT", 5*time.Minute),
		PollingInterval:          getEnvDuration("POLLING_INTERVAL", 5*time.Second),
		DevEndpoint:              getEnv("DEV_ENDPOINT", ""),
	}
}

func getEnv(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func getEnvBool(key string, defaultValue bool) bool {
	if value := os.Getenv(key); value != "" {
		b, err := strconv.ParseBool(value)
		if err == nil {
			return b
		}
	}
	return defaultValue
}

func getEnvDuration(key string, defaultValue time.Duration) time.Duration {
	if value := os.Getenv(key); value != "" {
		d, err := time.ParseDuration(value)
		if err == nil {
			return d
		}
	}
	return defaultValue
}

func getEnvFloat(key string, defaultValue float64) float64 {
	if value := os.Getenv(key); value != "" {
		f, err := strconv.ParseFloat(value, 64)
		if err == nil {
			return f
		}
	}
	return defaultValue
}
