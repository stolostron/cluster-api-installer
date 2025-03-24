package hook

import (
	"context"
	"encoding/json"
	"github.com/go-logr/logr"
	"gomodules.xyz/jsonpatch/v2"
	admissionv1 "k8s.io/api/admission/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/kube-openapi/pkg/validation/errors"
	"net/http"
	"sigs.k8s.io/controller-runtime/pkg/client"
	logf "sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/webhook/admission"
)

var log = logf.Log.WithName("example-controller")

// +kubebuilder:webhook:path=/mutate,mutating=true,failurePolicy=fail,groups="cluster.x-k8s.io",verbs=create;update,versions=v1,name=mce-label-injector.x-k8s.io

// MceLabelInjector label MCE objects for groups="cluster.x-k8s.io"
type MceLabelInjector struct {
	Client         client.Client
	MceLabelConfig *Config
	ClientSet      *kubernetes.Clientset
	Log            logr.Logger
}

type Config struct {
	NamespaceOpenshiftClusterApi string `default:"openshift-cluster-api"                        yaml:"namespace_openshift_cluster_api"`
	HyperShiftLabelName          string `default:"hypershift.openshift.io/hosted-control-plane" yaml:"hyper_shift_label_name"`
	LabelMultiClusterEngine      string `default:"multicluster-engine"                          yaml:"label_multi_cluster_engine"`
}

func (li *MceLabelInjector) countLabel(ctx context.Context, namespaceName string, oldValue string) (string, bool, error) {
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

	// If the namespace is openshift-cluster-api, don't label for MCE
	if namespaceName == li.MceLabelConfig.NamespaceOpenshiftClusterApi {
		return "", false, nil
	} else {
		// Else, fetch the NS and inspect labels
		namespace, err := li.ClientSet.CoreV1().Namespaces().Get(ctx, namespaceName, metav1.GetOptions{})
		if err != nil {
			return "", false, errors.New(0, "Cannot get namespace='%s' : %s", namespaceName, err.Error())
		}
		hyperShiftValue, isHyperShift := namespace.Labels[li.MceLabelConfig.HyperShiftLabelName]
		if isHyperShift && hyperShiftValue == "true" {
			return "", false, nil
		}
	}

	// If we've not returned by now, add the MCE label
	newLabel = li.MceLabelConfig.LabelMultiClusterEngine

	// If the NS is for (HyperShift or openshift-cluster-api) AND already has the MCE label, reject the admission, invalid configuration
	if oldValue != "" && oldValue != newLabel {
		return "", false, errors.New(0, "Invalid configuration, cannot change the label %s -> %s", oldValue, newLabel)
	}
	return newLabel, true, nil
}

// Handle MceLabelInjector label resources managed by MCE capi instance.
func (li *MceLabelInjector) Handle(ctx context.Context, req admission.Request) admission.Response {
	log.Info("handle", "namespace", req.Namespace, "kind", req.Kind, "name", req.Name)
	var obj metav1.PartialObjectMetadata
	if err := json.Unmarshal(req.Object.Raw, &obj); err != nil {
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
		return admission.ValidationResponse(false, errReject.Error())
	}
	if !change {
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
