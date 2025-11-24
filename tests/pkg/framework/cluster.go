package framework

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// ClusterConfig defines the configuration for creating a test cluster
type ClusterConfig struct {
	Name              string
	KubernetesVersion string
	Memory            string
	CPUs              string
	DiskSize          string
	Driver            string
	Addons            []string
}

// DefaultClusterConfig returns a default configuration for test clusters
func DefaultClusterConfig() ClusterConfig {
	return ClusterConfig{
		KubernetesVersion: "v1.28.0",
		Memory:            "4096",
		CPUs:              "2", 
		DiskSize:          "20g",
		Driver:            "docker",
		Addons:            []string{"ingress", "metallb"},
	}
}

// Cluster represents a minikube test cluster
type Cluster struct {
	name       string
	config     ClusterConfig
	kubeconfig string
	t          *testing.T
}

// NewMinikubeCluster creates a new minikube cluster for testing
func NewMinikubeCluster(t *testing.T, config ClusterConfig) *Cluster {
	if config.Name == "" {
		config.Name = fmt.Sprintf("capi-test-%d", time.Now().Unix())
	}

	cluster := &Cluster{
		name:   config.Name,
		config: config,
		t:      t,
	}

	t.Logf("Creating minikube cluster: %s", cluster.name)
	
	// Check if minikube is available
	if err := cluster.checkMinikube(); err != nil {
		t.Fatalf("minikube not available: %v", err)
	}

	// Start cluster
	if err := cluster.start(); err != nil {
		t.Fatalf("failed to start minikube cluster: %v", err)
	}

	// Setup kubeconfig
	if err := cluster.setupKubeconfig(); err != nil {
		t.Fatalf("failed to setup kubeconfig: %v", err)
	}

	// Enable addons
	if err := cluster.enableAddons(); err != nil {
		t.Logf("warning: failed to enable some addons: %v", err)
	}

	t.Logf("Minikube cluster %s ready", cluster.name)
	return cluster
}

// checkMinikube verifies minikube is installed and available
func (c *Cluster) checkMinikube() error {
	cmd := exec.Command("minikube", "version")
	return cmd.Run()
}

// start creates and starts the minikube cluster
func (c *Cluster) start() error {
	args := []string{
		"start",
		"--profile", c.name,
		"--driver", c.config.Driver,
		"--kubernetes-version", c.config.KubernetesVersion,
		"--memory", c.config.Memory,
		"--cpus", c.config.CPUs,
		"--disk-size", c.config.DiskSize,
		"--wait=all",
		"--delete-on-failure",
	}

	cmd := exec.Command("minikube", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	
	c.t.Logf("Starting minikube with command: minikube %s", strings.Join(args, " "))
	
	return cmd.Run()
}

// setupKubeconfig configures the kubeconfig for the cluster
func (c *Cluster) setupKubeconfig() error {
	// Get kubeconfig path
	cmd := exec.Command("minikube", "kubeconfig", "--profile", c.name)
	output, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("failed to get kubeconfig path: %w", err)
	}

	c.kubeconfig = strings.TrimSpace(string(output))
	
	// Verify kubeconfig works
	_, err = clientcmd.LoadFromFile(c.kubeconfig)
	if err != nil {
		return fmt.Errorf("invalid kubeconfig: %w", err)
	}

	c.t.Logf("Using kubeconfig: %s", c.kubeconfig)
	return nil
}

// enableAddons enables the configured addons
func (c *Cluster) enableAddons() error {
	for _, addon := range c.config.Addons {
		cmd := exec.Command("minikube", "addons", "enable", addon, "--profile", c.name)
		if err := cmd.Run(); err != nil {
			c.t.Logf("failed to enable addon %s: %v", addon, err)
		} else {
			c.t.Logf("enabled addon: %s", addon)
		}
	}
	return nil
}

// KubeConfig returns the path to the kubeconfig file
func (c *Cluster) KubeConfig() string {
	return c.kubeconfig
}

// Name returns the cluster name
func (c *Cluster) Name() string {
	return c.name
}

// K8sClient returns a controller-runtime client for the cluster
func (c *Cluster) K8sClient() client.Client {
	config, err := clientcmd.LoadFromFile(c.kubeconfig)
	require.NoError(c.t, err)

	clientConfig, err := clientcmd.NewDefaultClientConfig(*config, nil).ClientConfig()
	require.NoError(c.t, err)

	k8sClient, err := client.New(clientConfig, client.Options{})
	require.NoError(c.t, err)

	return k8sClient
}

// ClientSet returns a typed kubernetes client
func (c *Cluster) ClientSet() kubernetes.Interface {
	config, err := clientcmd.LoadFromFile(c.kubeconfig)
	require.NoError(c.t, err)

	clientConfig, err := clientcmd.NewDefaultClientConfig(*config, nil).ClientConfig()
	require.NoError(c.t, err)

	clientset, err := kubernetes.NewForConfig(clientConfig)
	require.NoError(c.t, err)

	return clientset
}

// StartTunnel starts minikube tunnel for LoadBalancer access
func (c *Cluster) StartTunnel(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "minikube", "tunnel", "--profile", c.name)
	return cmd.Start()
}

// GetServiceURL gets the URL for a service (useful for webhooks)
func (c *Cluster) GetServiceURL(namespace, serviceName string) (string, error) {
	cmd := exec.Command("minikube", "service", serviceName, "--namespace", namespace, "--url", "--profile", c.name)
	output, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("failed to get service URL: %w", err)
	}
	
	return strings.TrimSpace(string(output)), nil
}

// LoadDockerImage loads a docker image into the minikube cluster
func (c *Cluster) LoadDockerImage(imageName string) error {
	cmd := exec.Command("minikube", "image", "load", imageName, "--profile", c.name)
	return cmd.Run()
}

// Cleanup destroys the minikube cluster
func (c *Cluster) Cleanup() error {
	c.t.Logf("Cleaning up minikube cluster: %s", c.name)
	
	cmd := exec.Command("minikube", "delete", "--profile", c.name)
	err := cmd.Run()
	
	if err != nil {
		c.t.Logf("failed to delete cluster %s: %v", c.name, err)
		return err
	}
	
	c.t.Logf("Cluster %s deleted successfully", c.name)
	return nil
}

// Status returns the status of the minikube cluster
func (c *Cluster) Status() (string, error) {
	cmd := exec.Command("minikube", "status", "--profile", c.name, "--format", "{{.Host}}")
	output, err := cmd.Output()
	if err != nil {
		return "", err
	}
	
	return strings.TrimSpace(string(output)), nil
}

// WaitForClusterReady waits for the cluster to be in ready state
func (c *Cluster) WaitForClusterReady(ctx context.Context, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	
	for time.Now().Before(deadline) {
		status, err := c.Status()
		if err == nil && status == "Running" {
			return nil
		}
		
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
			// Continue checking
		}
	}
	
	return fmt.Errorf("cluster not ready after %v", timeout)
}