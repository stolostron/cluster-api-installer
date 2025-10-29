package hook

import (
	"context"
	"encoding/json"
	"gomodules.xyz/jsonpatch/v3"
	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/kube-openapi/pkg/validation/errors"
	"net/http"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/manager"
	"sigs.k8s.io/controller-runtime/pkg/webhook"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

var log = logf.Log.WithName("mce-capi-webhook")

// +kubebuilder:webhook:path=/mutate,mutating=true,failurePolicy=fail,groups="cluster.x-k8s.io",verbs=create;update,versions=v1,name=mce-capi-webhook-config.x-k8s.io

// MceCapiWebhookConfig label MCE objects for groups="cluster.x-k8s.io"
type MceCapiWebhookConfig struct {
	Client         client.Client
	MceLabelConfig *Config
	ClientSet      *kubernetes.Clientset
}

type Config struct {
	NamespaceOpenshiftClusterApi string
	HyperShiftLabelName          string
	LabelMultiClusterEngine      string
}

func NewConfig() *Config {
	return &Config{
		NamespaceOpenshiftClusterApi: "openshift-cluster-api",
		HyperShiftLabelName:          "hypershift.openshift.io/hosted-control-plane",
		LabelMultiClusterEngine:      "multicluster-engine",
	}
}

func SetupWebhookWithManager(restConfig *rest.Config, mgr manager.Manager) error {
	// creates the clientSet
	clientSet, errClientSet := kubernetes.NewForConfig(restConfig)
	if errClientSet != nil {
		return errClientSet
	}

	// Setup webhooks
	hookServer := mgr.GetWebhookServer()

	ha := &MceCapiWebhookConfig{Client: mgr.GetClient(), ClientSet: clientSet, MceLabelConfig: NewConfig()}
	hookServer.Register("/mutate", &webhook.Admission{Handler: ha})
	return nil
}

func (li *MceCapiWebhookConfig) countLabel(ctx context.Context, namespaceName string, oldValue string) (string, bool, error) {
	/*
		* The auto-labeling mutating webhook inspects the NS
		  * If the namespace is openshift-cluster-api, don't label for MCE
		  * Else, fetch the NS and inspect labels
		    * If it has the hypershift label, don't label for MCE
		  * If the NS is for (HyperShift or openshift-cluster-api) AND already has the MCE label, reject the admission, invalid configuration
		  * If we've not returned by now, add the MCE label
		* Relevant controller acts on CR
		  * MCE using a watchfilter on their label
	*/

	newLabel := ""

	isValidNamespace := true
	// If the namespace is openshift-cluster-api, don't label for MCE
	if namespaceName == li.MceLabelConfig.NamespaceOpenshiftClusterApi {
		isValidNamespace = false
	} else {
		// Else, fetch the NS and inspect labels
		namespace, err := li.ClientSet.CoreV1().Namespaces().Get(ctx, namespaceName, metav1.GetOptions{})
		if err != nil {
			return "", false, errors.New(0, "Cannot get namespace='%s' : %s", namespaceName, err.Error())
		}
		hyperShiftValue, isHyperShift := namespace.Labels[li.MceLabelConfig.HyperShiftLabelName]
		if isHyperShift && hyperShiftValue == "true" {
			isValidNamespace = false
		}
	}

	// If the NS is for (HyperShift or openshift-cluster-api) AND already has the MCE label, reject the admission, invalid configuration
	if !isValidNamespace {
		if oldValue == li.MceLabelConfig.LabelMultiClusterEngine {
			return "", false, errors.New(0, "Invalid configuration, cannot use label %q", oldValue)
		}
		return "", false, nil
	}

	// If we've not returned by now, add the MCE label
	newLabel = li.MceLabelConfig.LabelMultiClusterEngine

	if oldValue == "" {
		// not labeled -> add the label
		return newLabel, true, nil
	}

	if oldValue == newLabel {
		// labeled correctly -> no change is required
		return "", false, nil
	}

	return "", false, errors.New(0, "Invalid configuration, cannot use label %q (it should be: %q)", oldValue, newLabel)
}

// Handle MceCapiWebhookConfig label resources managed by MCE capi instance.
func (li *MceCapiWebhookConfig) Handle(ctx context.Context, req admission.Request) admission.Response {
	var obj metav1.PartialObjectMetadata
	if err := json.Unmarshal(req.Object.Raw, &obj); err != nil {
		log.Error(err, "handle", "namespace", req.Namespace, "kind", req.Kind, "name", req.Name)
		return admission.Errored(http.StatusBadRequest, err)
	}
	var patches []jsonpatch.JsonPatchOperation
	if obj.Labels == nil {
		obj.Labels = map[string]string{}
		patches = append(patches, jsonpatch.JsonPatchOperation{
			Operation: "add",
			Path:      "/metadata/labels",
			Value:     map[string]string{},
		})
	}
	oldLabelValue, ok := obj.Labels["cluster.x-k8s.io/watch-filter"]
	if !ok {
		oldLabelValue = ""
	}
	newLabelValue, change, errReject := li.countLabel(ctx, req.Namespace, oldLabelValue)
	if errReject != nil {
		log.Error(errReject, "handle", "namespace", req.Namespace, "kind", req.Kind, "name", req.Name)
		return admission.ValidationResponse(false, errReject.Error())
	}
	if !change {
		log.Info("handle", "namespace", req.Namespace, "kind", req.Kind, "name", req.Name, "response", "No change")
		return admission.ValidationResponse(true, "")
	}

	if oldLabelValue != newLabelValue {
		operation := "replace"
		if oldLabelValue == "" {
			operation = "add"
		}
		patches = append(patches, jsonpatch.JsonPatchOperation{
			Operation: operation,
			Path:      "/metadata/labels/cluster.x-k8s.io~1watch-filter",
			Value:     newLabelValue,
		})
		log.Info("handle", "namespace", req.Namespace, "kind", req.Kind, "name", req.Name, "response", operation, "old", oldLabelValue, "new", newLabelValue)
	}

	return admission.Response{
		Patches: patches,
		AdmissionResponse: admissionv1.AdmissionResponse{
			Allowed: true,
			PatchType: func() *admissionv1.PatchType {
				if len(patches) == 0 {
					return nil
				}
				pt := admissionv1.PatchTypeJSONPatch
				return &pt
			}(),
		},
	}
}
