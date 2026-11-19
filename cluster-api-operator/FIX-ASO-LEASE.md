# Fix for ASO Leader Election Issue

## Problem

ASO is in CrashLoopBackoff with a corrupt leader election lease:

**Symptoms:**
```
$ kubectl get pods -n capz-system
NAME                                                      READY   STATUS             RESTARTS
azureserviceoperator-controller-manager-xxxxx             0/1     CrashLoopBackOff   56
```

**Corrupt lease indicators:**
```yaml
leaseDurationSeconds: 1        # Should be 15!
holderIdentity: ""             # Should have pod name!
leaseTransitions: 56           # Should be 0-2!
```

## Root Cause

A corrupt pre-existing Kubernetes lease from a previous deployment or failed upgrade. ASO cannot start because it's trying to acquire a malformed lease.

---

## Solution 1: Delete the Corrupt Lease (Recommended)

This is the quickest fix:

```bash
# Step 1: Delete the corrupt lease
kubectl delete lease -n capz-system controllers-leader-election-azinfra-generated

# Step 2: Restart ASO to recreate the lease
kubectl rollout restart deployment/azureserviceoperator-controller-manager -n capz-system

# Step 3: Wait for ASO to be ready
kubectl rollout status deployment/azureserviceoperator-controller-manager -n capz-system
```

**Verify the fix:**
```bash
# Check lease duration (should be 15)
kubectl get lease -n capz-system controllers-leader-election-azinfra-generated -o jsonpath='{.spec.leaseDurationSeconds}'

# Check holderIdentity is populated (should show pod name)
kubectl get lease -n capz-system controllers-leader-election-azinfra-generated -o jsonpath='{.spec.holderIdentity}'

# Check pod is running
kubectl get pods -n capz-system | grep azureserviceoperator
```

---

## Solution 2: Toggle Leader Election (Alternative)

If deleting the lease doesn't work:

```bash
# Step 1: Disable leader election temporarily
kubectl patch infrastructureprovider azure -n capz-system --type=json -p '[
  {
    "op": "replace",
    "path": "/spec/additionalDeployments/azureserviceoperator-controller-manager/deployment/containers/0/args",
    "value": [
      "--enable-leader-election=false",
      "--crd-pattern=authorization.azure.com/*;managedidentity.azure.com/*;network.azure.com/*;eventhub.azure.com/*;storage.azure.com/*;web.azure.com/*;insights.azure.com/*;keyvault.azure.com/*",
      "--secure-metrics=false"
    ]
  }
]'

# Step 2: Wait for ASO to start (without leader election)
kubectl rollout status deployment/azureserviceoperator-controller-manager -n capz-system

# Step 3: Re-enable leader election
kubectl patch infrastructureprovider azure -n capz-system --type=json -p '[
  {
    "op": "replace",
    "path": "/spec/additionalDeployments/azureserviceoperator-controller-manager/deployment/containers/0/args",
    "value": [
      "--enable-leader-election",
      "--crd-pattern=authorization.azure.com/*;managedidentity.azure.com/*;network.azure.com/*;eventhub.azure.com/*;storage.azure.com/*;web.azure.com/*;insights.azure.com/*;keyvault.azure.com/*",
      "--secure-metrics=false"
    ]
  }
]'

# Step 4: Verify ASO creates a healthy lease
kubectl get lease -n capz-system controllers-leader-election-azinfra-generated -o yaml
```

---

## Expected Healthy Lease

After the fix, the lease should look like:

```yaml
apiVersion: coordination.k8s.io/v1
kind: Lease
metadata:
  name: controllers-leader-election-azinfra-generated
  namespace: capz-system
spec:
  acquireTime: "2026-02-20T09:44:02.354204Z"
  holderIdentity: azureserviceoperator-controller-manager-d7dd4bb74-xzkmr_b2515446-e923-46a5-9f78-5b3ef9adab45
  leaseDurationSeconds: 15      # ✅ Correct (not 1!)
  leaseTransitions: 0           # ✅ Low number (not 50+!)
  renewTime: "2026-02-20T09:48:07.372127Z"
```

---

## Prevention

To prevent this issue in the future:

1. **Always delete old leases** before redeploying the infrastructure provider:
   ```bash
   kubectl delete lease -n capz-system controllers-leader-election-azinfra-generated
   ```

2. **Check for corrupt leases** after any failed deployments:
   ```bash
   kubectl get lease -n capz-system -o yaml
   ```

3. **Monitor ASO pod restarts**:
   ```bash
   kubectl get pods -n capz-system -w
   ```

---

## Additional Diagnostics

If ASO still won't start after fixing the lease:

```bash
# Check ASO logs for other errors
kubectl logs -n capz-system deployment/azureserviceoperator-controller-manager --tail=100

# Check pod events
kubectl describe pod -n capz-system -l control-plane=azureserviceoperator-controller-manager

# Check for resource limits (OOMKilled)
kubectl get pods -n capz-system -l control-plane=azureserviceoperator-controller-manager -o jsonpath='{.items[*].status.containerStatuses[*].lastState}'
```
