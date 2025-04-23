package hook

import (
	"fmt"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/types"
	clusterv1 "sigs.k8s.io/cluster-api/api/v1beta1"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

var _ = Describe("MCE labeling webhook", func() {
	var (
		whConfig                     = NewConfig()
		nsOcp, nsHcp, nsMce1, nsMce2 *v1.Namespace
	)
	It("Init namespaces", func() {
		nsOcp = &v1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: whConfig.NamespaceOpenshiftClusterApi,
			},
		}
		Expect(k8sClient.Create(ctx, nsOcp)).Should(Succeed())

		nsHcp = &v1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: "hcp",
				Labels: map[string]string{
					whConfig.HyperShiftLabelName: "true",
				},
			},
		}
		Expect(k8sClient.Create(ctx, nsHcp)).Should(Succeed())

		nsMce1 = &v1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: "non-hcp1",
				Labels: map[string]string{
					whConfig.HyperShiftLabelName: "false",
				},
			},
		}
		Expect(k8sClient.Create(ctx, nsMce1)).Should(Succeed())

		nsMce2 = &v1.Namespace{
			ObjectMeta: metav1.ObjectMeta{
				Name: "non-hcp2",
			},
		}
		Expect(k8sClient.Create(ctx, nsMce2)).Should(Succeed())
	})

	Context("Inside the OCP namespace", func() {
		var ns *v1.Namespace
		BeforeEach(func() {
			ns = nsOcp
		})
		It("Should successfully create without a label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-1-%s", ns.Name),
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).NotTo(HaveKey("cluster.x-k8s.io/watch-filter"))
			})
		})
		It("Should successfully create and accept the label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-2-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": "any-label",
						},
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).To(HaveKeyWithValue("cluster.x-k8s.io/watch-filter", "any-label"))
			})
		})
		It("Shouldn't create with MCE label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-3-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": whConfig.LabelMultiClusterEngine,
						},
					},
				}
				err := k8sClient.Create(ctx, mch)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Message).Should(Equal(fmt.Sprintf("admission webhook %q denied the request: Invalid configuration, cannot use label %q",
					"multiclusterhub.validating-webhook.open-cluster-management.io", "multicluster-engine")))
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				err = k8sClient.Get(ctx, name, result)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Reason).Should(Equal(metav1.StatusReasonNotFound))
			})
		})
	})

	Context("Inside the HCP namespace", func() {
		var ns *v1.Namespace
		BeforeEach(func() {
			ns = nsHcp
		})
		It("Should successfully create without a label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-1-%s", ns.Name),
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).NotTo(HaveKey("cluster.x-k8s.io/watch-filter"))
			})
		})
		It("Should successfully create and accept the label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-2-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": "any-label",
						},
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).To(HaveKeyWithValue("cluster.x-k8s.io/watch-filter", "any-label"))
			})
		})
		It("Shouldn't create with MCE label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-3-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": whConfig.LabelMultiClusterEngine,
						},
					},
				}
				err := k8sClient.Create(ctx, mch)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Message).Should(Equal(fmt.Sprintf("admission webhook %q denied the request: Invalid configuration, cannot use label %q",
					"multiclusterhub.validating-webhook.open-cluster-management.io", "multicluster-engine")))
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				err = k8sClient.Get(ctx, name, result)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Reason).Should(Equal(metav1.StatusReasonNotFound))
			})
		})
	})

	Context("Inside non MCE namespace 1", func() {
		var ns *v1.Namespace
		BeforeEach(func() {
			ns = nsMce1
		})
		It("Should successfully create adding the label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-1-%s", ns.Name),
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).To(HaveKeyWithValue("cluster.x-k8s.io/watch-filter", whConfig.LabelMultiClusterEngine))
			})
		})
		It("Should successfully create and accept the label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-2-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": whConfig.LabelMultiClusterEngine,
						},
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).To(HaveKeyWithValue("cluster.x-k8s.io/watch-filter", whConfig.LabelMultiClusterEngine))
			})
		})
		It("Shouldn't create with non MCE label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-3-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": "other-label",
						},
					},
				}
				err := k8sClient.Create(ctx, mch)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Message).Should(Equal(fmt.Sprintf("admission webhook %q denied the request: Invalid configuration, cannot use label %q (it should be: %q)",
					"multiclusterhub.validating-webhook.open-cluster-management.io", "other-label", "multicluster-engine")))
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				err = k8sClient.Get(ctx, name, result)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Reason).Should(Equal(metav1.StatusReasonNotFound))
			})
		})
	})

	Context("Inside non MCE namespace 2", func() {
		var ns *v1.Namespace
		BeforeEach(func() {
			ns = nsMce2
		})
		It("Should successfully create adding the label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-1-%s", ns.Name),
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).To(HaveKeyWithValue("cluster.x-k8s.io/watch-filter", whConfig.LabelMultiClusterEngine))
			})
		})
		It("Should successfully create and accept the label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-2-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": whConfig.LabelMultiClusterEngine,
						},
					},
				}
				Expect(k8sClient.Create(ctx, mch)).Should(Succeed())
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				Expect(k8sClient.Get(ctx, name, result)).Should(Succeed())
				Expect(result.ObjectMeta.Labels).To(HaveKeyWithValue("cluster.x-k8s.io/watch-filter", whConfig.LabelMultiClusterEngine))
			})
		})
		It("Shouldn't create with non MCE label", func() {
			By("by creating a CAPI Cluster", func() {
				mch := &clusterv1.Cluster{
					ObjectMeta: metav1.ObjectMeta{
						Namespace: ns.Name,
						Name:      fmt.Sprintf("my-cluster-3-%s", ns.Name),
						Labels: map[string]string{
							"cluster.x-k8s.io/watch-filter": "other-label",
						},
					},
				}
				err := k8sClient.Create(ctx, mch)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Message).Should(Equal(fmt.Sprintf("admission webhook %q denied the request: Invalid configuration, cannot use label %q (it should be: %q)",
					"multiclusterhub.validating-webhook.open-cluster-management.io", "other-label", "multicluster-engine")))
				name := types.NamespacedName{Name: mch.Name, Namespace: mch.Namespace}
				result := &clusterv1.Cluster{}
				err = k8sClient.Get(ctx, name, result)
				Expect(err).To(HaveOccurred())
				Expect(err.(*errors.StatusError).ErrStatus.Status).Should(Equal(metav1.StatusFailure))
				Expect(err.(*errors.StatusError).ErrStatus.Reason).Should(Equal(metav1.StatusReasonNotFound))
			})
		})
	})
})
