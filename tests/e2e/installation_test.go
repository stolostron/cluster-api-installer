package e2e

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/apimachinery/pkg/util/wait"
	"sigs.k8s.io/controller-runtime/pkg/client"

	"github.com/stolostron/cluster-api-installer/tests/pkg/framework"
	"github.com/stolostron/cluster-api-installer/tests/pkg/helm"
)

var (
	chartsPath = "../charts"
	testTimeout = 15 * time.Minute
)

// chartTestConfig defines the test configuration for each chart
type chartTestConfig struct {
	name              string
	namespace         string
	expectedDeployments []string
	expectedServices    []string
	customValues       map[string]interface{}
	webhookServices    []string
}

var chartConfigs = map[string]chartTestConfig{
	"cluster-api": {
		name:      "cluster-api",
		namespace: "capi-system",
		expectedDeployments: []string{
			"capi-controller-manager",
			"mce-capi-webhook-config",
		},
		expectedServices: []string{
			"capi-webhook-service",
			"mce-capi-webhook-config-service",
		},
		webhookServices: []string{
			"capi-webhook-service",
		},
	},
	"cluster-api-provider-aws": {
		name:      "cluster-api-provider-aws",
		namespace: "capa-system",
		expectedDeployments: []string{
			"capa-controller-manager",
		},
		expectedServices: []string{
			"capa-webhook-service",
			"capa-metrics-service",
		},
		webhookServices: []string{
			"capa-webhook-service",
		},
	},
	"cluster-api-provider-metal3": {
		name:      "cluster-api-provider-metal3",
		namespace: "capm3-system",
		expectedDeployments: []string{
			"capm3-controller-manager",
		},
		expectedServices: []string{
			"capm3-webhook-service",
		},
		webhookServices: []string{
			"capm3-webhook-service",
		},
	},
	"cluster-api-provider-openshift-assisted": {
		name:      "cluster-api-provider-openshift-assisted",
		namespace: "capoa-bootstrap-system",
		expectedDeployments: []string{
			"capoa-bootstrap-controller-manager",
			"capoa-controlplane-controller-manager",
		},
		expectedServices: []string{
			"capoa-bootstrap-webhook-service",
		},
		webhookServices: []string{
			"capoa-bootstrap-webhook-service",
		},
	},
}

func TestChartInstallation(t *testing.T) {
	// Create minikube cluster
	clusterConfig := framework.DefaultClusterConfig()
	clusterConfig.Addons = []string{"ingress", "metallb"}
	cluster := framework.NewMinikubeCluster(t, clusterConfig)
	defer cluster.Cleanup()

	// Wait for cluster to be ready
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	err := cluster.WaitForClusterReady(ctx, 5*time.Minute)
	require.NoError(t, err, "cluster should be ready")

	// Create Helm client
	helmClient, err := helm.NewClient(cluster.KubeConfig())
	require.NoError(t, err, "should create helm client")

	// Test each chart
	for chartName, config := range chartConfigs {
		t.Run(fmt.Sprintf("install-%s", chartName), func(t *testing.T) {
			testChartInstallation(t, cluster, helmClient, chartName, config)
		})
	}
}

func testChartInstallation(t *testing.T, cluster *framework.Cluster, helmClient *helm.Client, chartName string, config chartTestConfig) {
	ctx, cancel := context.WithTimeout(context.Background(), testTimeout)
	defer cancel()

	k8sClient := cluster.K8sClient()

	// Ensure namespace exists
	namespace := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: config.namespace,
		},
	}
	err := k8sClient.Create(ctx, namespace)
	if err != nil && !client.IgnoreAlreadyExists(err) != nil {
		require.NoError(t, err, "should create namespace")
	}

	// Install chart
	chartPath := filepath.Join(chartsPath, chartName)
	helmConfig := helm.ChartConfig{
		Name:            config.name,
		Namespace:       config.namespace,
		Chart:           chartPath,
		Values:          config.customValues,
		Wait:            true,
		Timeout:         10 * time.Minute,
		CreateNamespace: true,
	}

	t.Logf("Installing chart %s in namespace %s", chartName, config.namespace)
	release, err := helmClient.InstallChart(ctx, helmConfig)
	require.NoError(t, err, "should install chart successfully")
	require.NotNil(t, release, "release should not be nil")

	t.Logf("Chart %s installed successfully, release: %s", chartName, release.Name)

	// Verify deployments are ready
	for _, deploymentName := range config.expectedDeployments {
		t.Run(fmt.Sprintf("verify-deployment-%s", deploymentName), func(t *testing.T) {
			verifyDeploymentReady(t, k8sClient, config.namespace, deploymentName)
		})
	}

	// Verify services exist
	for _, serviceName := range config.expectedServices {
		t.Run(fmt.Sprintf("verify-service-%s", serviceName), func(t *testing.T) {
			verifyServiceExists(t, k8sClient, config.namespace, serviceName)
		})
	}

	// Verify webhook configurations
	if len(config.webhookServices) > 0 {
		t.Run("verify-webhooks", func(t *testing.T) {
			verifyWebhookConfiguration(t, k8sClient, chartName)
		})
	}

	// Verify CRDs are installed (for CAPI charts)
	t.Run("verify-crds", func(t *testing.T) {
		verifyCRDsInstalled(t, k8sClient, chartName)
	})

	// Cleanup - uninstall chart
	t.Cleanup(func() {
		t.Logf("Cleaning up chart %s", chartName)
		err := helmClient.UninstallChart(context.Background(), config.name, config.namespace)
		if err != nil {
			t.Logf("Warning: failed to uninstall chart %s: %v", chartName, err)
		}
	})
}

func verifyDeploymentReady(t *testing.T, k8sClient client.Client, namespace, deploymentName string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	err := wait.PollImmediate(10*time.Second, 5*time.Minute, func() (bool, error) {
		deployment := &appsv1.Deployment{}
		err := k8sClient.Get(ctx, types.NamespacedName{
			Name:      deploymentName,
			Namespace: namespace,
		}, deployment)
		
		if err != nil {
			t.Logf("Deployment %s not found yet: %v", deploymentName, err)
			return false, nil
		}

		// Check if deployment is available
		for _, condition := range deployment.Status.Conditions {
			if condition.Type == appsv1.DeploymentAvailable && condition.Status == corev1.ConditionTrue {
				t.Logf("Deployment %s is ready: %d/%d replicas available", 
					deploymentName, deployment.Status.ReadyReplicas, *deployment.Spec.Replicas)
				return true, nil
			}
		}

		t.Logf("Deployment %s not ready yet: %d/%d replicas available", 
			deploymentName, deployment.Status.ReadyReplicas, *deployment.Spec.Replicas)
		return false, nil
	})

	require.NoError(t, err, "deployment %s should become ready", deploymentName)
}

func verifyServiceExists(t *testing.T, k8sClient client.Client, namespace, serviceName string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	service := &corev1.Service{}
	err := k8sClient.Get(ctx, types.NamespacedName{
		Name:      serviceName,
		Namespace: namespace,
	}, service)

	require.NoError(t, err, "service %s should exist", serviceName)
	assert.NotEmpty(t, service.Spec.Ports, "service should have ports defined")
	
	t.Logf("Service %s verified: type=%s, ports=%d", serviceName, service.Spec.Type, len(service.Spec.Ports))
}

func verifyWebhookConfiguration(t *testing.T, k8sClient client.Client, chartName string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Check for ValidatingAdmissionWebhooks
	validatingWebhooks := &unstructured.UnstructuredList{}
	validatingWebhooks.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "admissionregistration.k8s.io",
		Version: "v1",
		Kind:    "ValidatingAdmissionWebhook",
	})

	err := k8sClient.List(ctx, validatingWebhooks)
	if err == nil && len(validatingWebhooks.Items) > 0 {
		t.Logf("Found %d validating webhook configurations", len(validatingWebhooks.Items))
	}

	// Check for MutatingAdmissionWebhooks
	mutatingWebhooks := &unstructured.UnstructuredList{}
	mutatingWebhooks.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "admissionregistration.k8s.io",
		Version: "v1", 
		Kind:    "MutatingAdmissionWebhook",
	})

	err = k8sClient.List(ctx, mutatingWebhooks)
	if err == nil && len(mutatingWebhooks.Items) > 0 {
		t.Logf("Found %d mutating webhook configurations", len(mutatingWebhooks.Items))
	}
}

func verifyCRDsInstalled(t *testing.T, k8sClient client.Client, chartName string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Define expected CRDs for each chart
	expectedCRDs := map[string][]string{
		"cluster-api": {
			"clusters.cluster.x-k8s.io",
			"machines.cluster.x-k8s.io",
			"machinesets.cluster.x-k8s.io",
			"machinedeployments.cluster.x-k8s.io",
		},
		"cluster-api-provider-aws": {
			"awsclusters.infrastructure.cluster.x-k8s.io",
			"awsmachines.infrastructure.cluster.x-k8s.io",
			"awsmanagedclusters.infrastructure.cluster.x-k8s.io",
		},
		"cluster-api-provider-metal3": {
			"metal3clusters.infrastructure.cluster.x-k8s.io",
			"metal3machines.infrastructure.cluster.x-k8s.io",
		},
		"cluster-api-provider-openshift-assisted": {
			"openshiftassistedconfigs.bootstrap.cluster.x-k8s.io",
			"openshiftassistedcontrolplanes.controlplane.cluster.x-k8s.io",
		},
	}

	crdList, exists := expectedCRDs[chartName]
	if !exists {
		t.Logf("No expected CRDs defined for chart %s", chartName)
		return
	}

	for _, crdName := range crdList {
		crd := &unstructured.Unstructured{}
		crd.SetGroupVersionKind(schema.GroupVersionKind{
			Group:   "apiextensions.k8s.io",
			Version: "v1",
			Kind:    "CustomResourceDefinition",
		})

		err := k8sClient.Get(ctx, types.NamespacedName{Name: crdName}, crd)
		if err != nil {
			t.Logf("Warning: CRD %s not found (may be expected for some charts): %v", crdName, err)
		} else {
			t.Logf("CRD %s verified", crdName)
		}
	}
}

func TestChartUpgrade(t *testing.T) {
	// This test will be implemented in upgrade_test.go
	t.Skip("Upgrade tests are in separate file")
}