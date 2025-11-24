package main

import (
	"context"
	"flag"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/stolostron/cluster-api-installer/tests/pkg/runner"
)

type config struct {
	kubeconfig    string
	chartsPath    string
	testSuite     string
	chartFilter   string
	providerFilter string
	timeout       time.Duration
	verbose       bool
	cleanup       bool
}

func main() {
	cfg := parseFlags()
	
	if cfg.verbose {
		log.SetFlags(log.LstdFlags | log.Lshortfile)
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.timeout)
	defer cancel()

	// Validate charts path
	if _, err := os.Stat(cfg.chartsPath); os.IsNotExist(err) {
		log.Fatalf("Charts path does not exist: %s", cfg.chartsPath)
	}

	// Create test runner
	testRunner := &runner.TestRunner{
		KubeConfig:     cfg.kubeconfig,
		ChartsPath:     cfg.chartsPath,
		ChartFilter:    cfg.chartFilter,
		ProviderFilter: cfg.providerFilter,
		Verbose:        cfg.verbose,
	}

	var err error
	switch cfg.testSuite {
	case "installation":
		err = testRunner.RunInstallationTests(ctx)
	case "upgrade":
		err = testRunner.RunUpgradeTests(ctx)
	case "functionality":
		err = testRunner.RunFunctionalityTests(ctx)
	case "all":
		err = testRunner.RunAllTests(ctx)
	default:
		log.Fatalf("Unknown test suite: %s", cfg.testSuite)
	}

	if err != nil {
		log.Fatalf("Test execution failed: %v", err)
	}

	log.Println("All tests completed successfully")
}

func parseFlags() config {
	var cfg config

	flag.StringVar(&cfg.kubeconfig, "kubeconfig", "", "Path to kubeconfig file")
	flag.StringVar(&cfg.chartsPath, "charts-path", "./charts", "Path to charts directory")
	flag.StringVar(&cfg.testSuite, "test-suite", "installation", "Test suite to run (installation, upgrade, functionality, all)")
	flag.StringVar(&cfg.chartFilter, "chart-filter", "", "Filter to specific chart (empty for all)")
	flag.StringVar(&cfg.providerFilter, "provider-filter", "", "Filter to specific provider (empty for all)")
	flag.DurationVar(&cfg.timeout, "timeout", 30*time.Minute, "Overall test timeout")
	flag.BoolVar(&cfg.verbose, "verbose", false, "Enable verbose logging")
	flag.BoolVar(&cfg.cleanup, "cleanup", true, "Cleanup resources after tests")

	flag.Parse()

	// Validate required flags
	if cfg.kubeconfig == "" {
		if kubeconfig := os.Getenv("KUBECONFIG"); kubeconfig != "" {
			cfg.kubeconfig = kubeconfig
		} else {
			homeDir, _ := os.UserHomeDir()
			cfg.kubeconfig = filepath.Join(homeDir, ".kube", "config")
		}
	}

	return cfg
}