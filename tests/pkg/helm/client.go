package helm

import (
	"context"
	"fmt"
	"os"
	"time"

	"helm.sh/helm/v3/pkg/action"
	"helm.sh/helm/v3/pkg/chart/loader"
	"helm.sh/helm/v3/pkg/cli"
	"helm.sh/helm/v3/pkg/cli/values"
	"helm.sh/helm/v3/pkg/getter"
	"helm.sh/helm/v3/pkg/release"
)

// ChartConfig defines the configuration for installing a Helm chart
type ChartConfig struct {
	Name         string
	Namespace    string
	Chart        string
	ValuesFile   string
	Values       map[string]interface{}
	Wait         bool
	Timeout      time.Duration
	CreateNamespace bool
}

// Client wraps Helm operations
type Client struct {
	actionConfig *action.Configuration
	settings     *cli.EnvSettings
}

// NewClient creates a new Helm client for the specified kubeconfig
func NewClient(kubeconfig string) (*Client, error) {
	settings := cli.New()
	
	// Set kubeconfig
	if kubeconfig != "" {
		settings.KubeConfig = kubeconfig
	}

	actionConfig := new(action.Configuration)
	
	// Initialize action configuration
	err := actionConfig.Init(settings.RESTClientGetter(), "default",
		os.Getenv("HELM_DRIVER"), func(format string, v ...interface{}) {
			fmt.Printf(format, v...)
		})
	if err != nil {
		return nil, fmt.Errorf("failed to initialize Helm action config: %w", err)
	}

	return &Client{
		actionConfig: actionConfig,
		settings:     settings,
	}, nil
}

// InstallChart installs a Helm chart with the given configuration
func (c *Client) InstallChart(ctx context.Context, config ChartConfig) (*release.Release, error) {
	// Create install action
	install := action.NewInstall(c.actionConfig)
	install.ReleaseName = config.Name
	install.Namespace = config.Namespace
	install.CreateNamespace = config.CreateNamespace
	install.Wait = config.Wait
	if config.Timeout > 0 {
		install.Timeout = config.Timeout
	} else {
		install.Timeout = 10 * time.Minute // Default timeout
	}

	// Load chart
	chart, err := loader.Load(config.Chart)
	if err != nil {
		return nil, fmt.Errorf("failed to load chart %s: %w", config.Chart, err)
	}

	// Prepare values
	valueOpts := &values.Options{}
	if config.ValuesFile != "" {
		valueOpts.ValueFiles = []string{config.ValuesFile}
	}

	// Merge values
	vals, err := valueOpts.MergeValues(getter.All(c.settings))
	if err != nil {
		return nil, fmt.Errorf("failed to merge values: %w", err)
	}

	// Add programmatic values
	for key, value := range config.Values {
		vals[key] = value
	}

	// Install the chart
	rel, err := install.RunWithContext(ctx, chart, vals)
	if err != nil {
		return nil, fmt.Errorf("failed to install chart %s: %w", config.Name, err)
	}

	return rel, nil
}

// UninstallChart uninstalls a Helm release
func (c *Client) UninstallChart(ctx context.Context, releaseName, namespace string) error {
	// Create new action config with the specified namespace
	actionConfig := new(action.Configuration)
	err := actionConfig.Init(c.settings.RESTClientGetter(), namespace,
		os.Getenv("HELM_DRIVER"), func(format string, v ...interface{}) {})
	if err != nil {
		return fmt.Errorf("failed to init action config: %w", err)
	}

	uninstall := action.NewUninstall(actionConfig)
	uninstall.Wait = true
	uninstall.Timeout = 5 * time.Minute

	_, err = uninstall.Run(releaseName)
	if err != nil {
		return fmt.Errorf("failed to uninstall release %s: %w", releaseName, err)
	}

	return nil
}

// UpgradeChart upgrades a Helm release
func (c *Client) UpgradeChart(ctx context.Context, config ChartConfig) (*release.Release, error) {
	upgrade := action.NewUpgrade(c.actionConfig)
	upgrade.Namespace = config.Namespace
	upgrade.Wait = config.Wait
	if config.Timeout > 0 {
		upgrade.Timeout = config.Timeout
	} else {
		upgrade.Timeout = 10 * time.Minute
	}

	// Load chart
	chart, err := loader.Load(config.Chart)
	if err != nil {
		return nil, fmt.Errorf("failed to load chart %s: %w", config.Chart, err)
	}

	// Prepare values
	valueOpts := &values.Options{}
	if config.ValuesFile != "" {
		valueOpts.ValueFiles = []string{config.ValuesFile}
	}

	vals, err := valueOpts.MergeValues(getter.All(c.settings))
	if err != nil {
		return nil, fmt.Errorf("failed to merge values: %w", err)
	}

	// Add programmatic values
	for key, value := range config.Values {
		vals[key] = value
	}

	// Upgrade the chart
	rel, err := upgrade.RunWithContext(ctx, config.Name, chart, vals)
	if err != nil {
		return nil, fmt.Errorf("failed to upgrade chart %s: %w", config.Name, err)
	}

	return rel, nil
}

// GetRelease gets information about a release
func (c *Client) GetRelease(releaseName, namespace string) (*release.Release, error) {
	// Create new action config with the specified namespace
	actionConfig := new(action.Configuration)
	err := actionConfig.Init(c.settings.RESTClientGetter(), namespace,
		os.Getenv("HELM_DRIVER"), func(format string, v ...interface{}) {})
	if err != nil {
		return nil, fmt.Errorf("failed to init action config: %w", err)
	}

	get := action.NewGet(actionConfig)
	rel, err := get.Run(releaseName)
	if err != nil {
		return nil, fmt.Errorf("failed to get release %s: %w", releaseName, err)
	}

	return rel, nil
}

// ListReleases lists all releases in the specified namespace
func (c *Client) ListReleases(namespace string) ([]*release.Release, error) {
	// Create new action config with the specified namespace
	actionConfig := new(action.Configuration)
	err := actionConfig.Init(c.settings.RESTClientGetter(), namespace,
		os.Getenv("HELM_DRIVER"), func(format string, v ...interface{}) {})
	if err != nil {
		return nil, fmt.Errorf("failed to init action config: %w", err)
	}

	list := action.NewList(actionConfig)
	list.All = true

	releases, err := list.Run()
	if err != nil {
		return nil, fmt.Errorf("failed to list releases: %w", err)
	}

	return releases, nil
}

// RollbackRelease rolls back a release to a previous revision
func (c *Client) RollbackRelease(ctx context.Context, releaseName, namespace string, revision int) error {
	// Create new action config with the specified namespace
	actionConfig := new(action.Configuration)
	err := actionConfig.Init(c.settings.RESTClientGetter(), namespace,
		os.Getenv("HELM_DRIVER"), func(format string, v ...interface{}) {})
	if err != nil {
		return fmt.Errorf("failed to init action config: %w", err)
	}

	rollback := action.NewRollback(actionConfig)
	rollback.Version = revision
	rollback.Wait = true
	rollback.Timeout = 5 * time.Minute

	err = rollback.Run(releaseName)
	if err != nil {
		return fmt.Errorf("failed to rollback release %s: %w", releaseName, err)
	}

	return nil
}

// TemplateChart renders chart templates locally without installing
func (c *Client) TemplateChart(config ChartConfig) (string, error) {
	template := action.NewInstall(c.actionConfig)
	template.DryRun = true
	template.ClientOnly = true
	template.ReleaseName = config.Name
	template.Namespace = config.Namespace

	// Load chart
	chart, err := loader.Load(config.Chart)
	if err != nil {
		return "", fmt.Errorf("failed to load chart %s: %w", config.Chart, err)
	}

	// Prepare values
	valueOpts := &values.Options{}
	if config.ValuesFile != "" {
		valueOpts.ValueFiles = []string{config.ValuesFile}
	}

	vals, err := valueOpts.MergeValues(getter.All(c.settings))
	if err != nil {
		return "", fmt.Errorf("failed to merge values: %w", err)
	}

	// Add programmatic values
	for key, value := range config.Values {
		vals[key] = value
	}

	// Render template
	rel, err := template.Run(chart, vals)
	if err != nil {
		return "", fmt.Errorf("failed to template chart %s: %w", config.Name, err)
	}

	return rel.Manifest, nil
}

// ValidateChart validates a chart's templates and values
func (c *Client) ValidateChart(chartPath string, valuesFile string) error {
	// Load chart to validate structure
	chart, err := loader.Load(chartPath)
	if err != nil {
		return fmt.Errorf("failed to load chart: %w", err)
	}

	// Validate chart metadata
	if chart.Metadata == nil {
		return fmt.Errorf("chart metadata is missing")
	}

	if chart.Metadata.Name == "" {
		return fmt.Errorf("chart name is required")
	}

	if chart.Metadata.Version == "" {
		return fmt.Errorf("chart version is required")
	}

	// Validate values file if provided
	if valuesFile != "" {
		if _, err := os.Stat(valuesFile); os.IsNotExist(err) {
			return fmt.Errorf("values file does not exist: %s", valuesFile)
		}
	}

	return nil
}