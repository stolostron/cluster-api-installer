package runner

import (
	"context"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"time"

	"github.com/stolostron/cluster-api-installer/tests/pkg/framework"
	"github.com/stolostron/cluster-api-installer/tests/pkg/helm"
)

// TestRunner orchestrates the execution of CAPI chart tests
type TestRunner struct {
	KubeConfig     string
	ChartsPath     string
	ChartFilter    string
	ProviderFilter string
	Verbose        bool

	cluster    *framework.Cluster
	helmClient *helm.Client
}

// ChartTestConfig defines configuration for testing a specific chart
type ChartTestConfig struct {
	Name                string
	Namespace           string
	ChartPath          string
	ExpectedDeployments []string
	ExpectedServices    []string
	WebhookServices     []string
	CustomValues       map[string]interface{}
}

var chartConfigs = map[string]ChartTestConfig{
	"cluster-api": {
		Name:      "cluster-api",
		Namespace: "capi-system",
		ExpectedDeployments: []string{
			"capi-controller-manager",
			"mce-capi-webhook-config",
		},
		ExpectedServices: []string{
			"capi-webhook-service",
			"mce-capi-webhook-config-service",
		},
		WebhookServices: []string{
			"capi-webhook-service",
		},
	},
	"cluster-api-provider-aws": {
		Name:      "cluster-api-provider-aws",
		Namespace: "capa-system",
		ExpectedDeployments: []string{
			"capa-controller-manager",
		},
		ExpectedServices: []string{
			"capa-webhook-service",
			"capa-metrics-service",
		},
		WebhookServices: []string{
			"capa-webhook-service",
		},
	},
	"cluster-api-provider-metal3": {
		Name:      "cluster-api-provider-metal3",
		Namespace: "capm3-system",
		ExpectedDeployments: []string{
			"capm3-controller-manager",
		},
		ExpectedServices: []string{
			"capm3-webhook-service",
		},
		WebhookServices: []string{
			"capm3-webhook-service",
		},
	},
	"cluster-api-provider-openshift-assisted": {
		Name:      "cluster-api-provider-openshift-assisted",
		Namespace: "capoa-bootstrap-system",
		ExpectedDeployments: []string{
			"capoa-bootstrap-controller-manager",
			"capoa-controlplane-controller-manager",
		},
		ExpectedServices: []string{
			"capoa-bootstrap-webhook-service",
		},
		WebhookServices: []string{
			"capoa-bootstrap-webhook-service",
		},
	},
}

// setup initializes the test environment
func (tr *TestRunner) setup(ctx context.Context) error {
	if tr.cluster == nil {
		// Setup cluster if not using external kubeconfig
		if tr.KubeConfig == "" || strings.Contains(tr.KubeConfig, "minikube") {
			config := framework.DefaultClusterConfig()
			config.Addons = []string{"ingress", "metallb"}
			tr.cluster = framework.NewMinikubeCluster(nil, config)
			
			// Wait for cluster readiness
			if err := tr.cluster.WaitForClusterReady(ctx, 5*time.Minute); err != nil {
				return fmt.Errorf("cluster not ready: %w", err)
			}
			tr.KubeConfig = tr.cluster.KubeConfig()
		}
	}

	// Create Helm client
	if tr.helmClient == nil {
		var err error
		tr.helmClient, err = helm.NewClient(tr.KubeConfig)
		if err != nil {
			return fmt.Errorf("failed to create helm client: %w", err)
		}
	}

	return nil
}

// cleanup tears down test resources
func (tr *TestRunner) cleanup() {
	if tr.cluster != nil {
		if err := tr.cluster.Cleanup(); err != nil {
			log.Printf("Warning: failed to cleanup cluster: %v", err)
		}
	}
}

// getChartsToTest returns the list of charts to test based on filters
func (tr *TestRunner) getChartsToTest() []string {
	var charts []string
	
	if tr.ChartFilter != "" {
		// Test specific chart
		if _, exists := chartConfigs[tr.ChartFilter]; exists {
			charts = []string{tr.ChartFilter}
		} else {
			log.Printf("Warning: chart filter '%s' not found in configurations", tr.ChartFilter)
		}
	} else {
		// Test all charts
		for chartName := range chartConfigs {
			charts = append(charts, chartName)
		}
	}

	// Apply provider filter if specified
	if tr.ProviderFilter != "" {
		var filteredCharts []string
		for _, chart := range charts {
			if strings.Contains(chart, tr.ProviderFilter) {
				filteredCharts = append(filteredCharts, chart)
			}
		}
		charts = filteredCharts
	}

	return charts
}

// RunInstallationTests runs chart installation tests
func (tr *TestRunner) RunInstallationTests(ctx context.Context) error {
	log.Println("Starting installation tests...")
	
	if err := tr.setup(ctx); err != nil {
		return fmt.Errorf("setup failed: %w", err)
	}
	defer tr.cleanup()

	charts := tr.getChartsToTest()
	if len(charts) == 0 {
		return fmt.Errorf("no charts to test")
	}

	log.Printf("Testing %d charts: %v", len(charts), charts)

	for _, chartName := range charts {
		log.Printf("Testing installation of chart: %s", chartName)
		
		if err := tr.testChartInstallation(ctx, chartName); err != nil {
			return fmt.Errorf("installation test failed for %s: %w", chartName, err)
		}
		
		log.Printf("✓ Installation test passed for chart: %s", chartName)
	}

	return nil
}

// RunUpgradeTests runs chart upgrade tests
func (tr *TestRunner) RunUpgradeTests(ctx context.Context) error {
	log.Println("Starting upgrade tests...")
	
	if err := tr.setup(ctx); err != nil {
		return fmt.Errorf("setup failed: %w", err)
	}
	defer tr.cleanup()

	charts := tr.getChartsToTest()
	
	for _, chartName := range charts {
		log.Printf("Testing upgrade of chart: %s", chartName)
		
		if err := tr.testChartUpgrade(ctx, chartName); err != nil {
			return fmt.Errorf("upgrade test failed for %s: %w", chartName, err)
		}
		
		log.Printf("✓ Upgrade test passed for chart: %s", chartName)
	}

	return nil
}

// RunFunctionalityTests runs CAPI functionality tests
func (tr *TestRunner) RunFunctionalityTests(ctx context.Context) error {
	log.Println("Starting functionality tests...")
	
	if err := tr.setup(ctx); err != nil {
		return fmt.Errorf("setup failed: %w", err)
	}
	defer tr.cleanup()

	charts := tr.getChartsToTest()
	
	for _, chartName := range charts {
		log.Printf("Testing functionality of chart: %s", chartName)
		
		if err := tr.testChartFunctionality(ctx, chartName); err != nil {
			return fmt.Errorf("functionality test failed for %s: %w", chartName, err)
		}
		
		log.Printf("✓ Functionality test passed for chart: %s", chartName)
	}

	return nil
}

// RunAllTests runs all test suites
func (tr *TestRunner) RunAllTests(ctx context.Context) error {
	log.Println("Starting all tests...")
	
	if err := tr.RunInstallationTests(ctx); err != nil {
		return fmt.Errorf("installation tests failed: %w", err)
	}
	
	if err := tr.RunUpgradeTests(ctx); err != nil {
		return fmt.Errorf("upgrade tests failed: %w", err)
	}
	
	if err := tr.RunFunctionalityTests(ctx); err != nil {
		return fmt.Errorf("functionality tests failed: %w", err)
	}

	return nil
}

// testChartInstallation tests the installation of a single chart
func (tr *TestRunner) testChartInstallation(ctx context.Context, chartName string) error {
	config, exists := chartConfigs[chartName]
	if !exists {
		return fmt.Errorf("no configuration found for chart: %s", chartName)
	}

	config.ChartPath = filepath.Join(tr.ChartsPath, chartName)
	
	// Install chart
	helmConfig := helm.ChartConfig{
		Name:            config.Name + "-test",
		Namespace:       config.Namespace,
		Chart:           config.ChartPath,
		Values:          config.CustomValues,
		Wait:            true,
		Timeout:         10 * time.Minute,
		CreateNamespace: true,
	}

	release, err := tr.helmClient.InstallChart(ctx, helmConfig)
	if err != nil {
		return fmt.Errorf("failed to install chart: %w", err)
	}

	log.Printf("Chart installed successfully: %s", release.Name)

	// Verify deployments, services, etc.
	// TODO: Implement verification logic similar to installation_test.go
	
	// Cleanup
	defer func() {
		if err := tr.helmClient.UninstallChart(context.Background(), config.Name+"-test", config.Namespace); err != nil {
			log.Printf("Warning: failed to uninstall chart %s: %v", config.Name+"-test", err)
		}
	}()

	return nil
}

// testChartUpgrade tests upgrading a chart
func (tr *TestRunner) testChartUpgrade(ctx context.Context, chartName string) error {
	// TODO: Implement upgrade testing logic
	log.Printf("Upgrade test for %s not yet implemented", chartName)
	return nil
}

// testChartFunctionality tests basic CAPI functionality
func (tr *TestRunner) testChartFunctionality(ctx context.Context, chartName string) error {
	// TODO: Implement functionality testing logic
	log.Printf("Functionality test for %s not yet implemented", chartName)
	return nil
}