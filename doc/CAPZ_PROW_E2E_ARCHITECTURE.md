# CAPZ PROW E2E Testing on DEV

---

## 1. How CAPZ/ASO uses the aro-mockup-proxy to split ARO-HCP requests

CAPZ and ASO do not talk to the ARO-HCP RP directly. All ARM traffic from ASO is routed through an **aro-mockup-proxy** deployed as a pod on the AKS management cluster. The proxy acts as a selective reverse proxy:

```
ASO (ARM client)
      |
      v
+-------------------------------------+
|        aro-mockup-proxy              |
|                                      |
|   Path: Microsoft.RedHatOpenShift?   |
|                                      |
|   YES                      NO        |
|   (hcpOpenShiftClusters,   (all other|
|    hcpOperationStatuses,    Azure    |
|    hcpOperationResults)    resources)|
|        |                      |      |
|        v                      v      |
|   DEV RP Frontend      management.   |
|   (via Istio gateway)  azure.com     |
|                        (real ARM)    |
+-------------------------------------+
```

### Routing rules in DEV Endpoint Forwarding Mode

| Request type | Destination |
|---|---|
| `hcpOpenShiftClusters` (CRUD + actions) | DEV RP Frontend → creates real clusters |
| `hcpOperationStatuses` / `hcpOperationResults` | DEV RP Frontend → LRO polling |
| `hcpOpenShiftVersions`, `hcpOperatorIdentityRoleSets` | Local SQLite mock (read-only metadata) |
| All other Azure resources (RG, KeyVault, ManagedIdentity, RoleAssignment, etc.) | Real Azure ARM (`management.azure.com`) |

### What the proxy does at request/response time

- **Injects ARM headers** that the frontend expects (`X-Ms-Arm-Resource-System-Data`, `X-Ms-Identity-Url`) — these are normally added by the ARM gateway, but requests via the proxy skip ARM
- **Rewrites LRO polling URLs** (`Azure-AsyncOperation`, `Location`) in responses to point back through the proxy so ASO polls correctly
- **Skips TLS verification** on the forwarded connection (the frontend is reached via port-forward or Istio gateway)

### Configuration

The proxy is controlled by environment variables:

| Variable | Purpose |
|---|---|
| `DEV_ENDPOINT` | When set, forward hcpOpenShiftCluster requests to this URL instead of SQLite mock |
| `AZURE_ENDPOINT` | Real Azure backend (default: `https://management.azure.com`) |
| `MOCK_PROXY_PORT` | Proxy listen address (default: `172.17.0.1:8443`) |

**Source code:** [stolostron/cluster-api-installer/aro-mockup-proxy/](https://github.com/stolostron/cluster-api-installer/tree/main/aro-mockup-proxy)

---

## 2. How `/test capz-e2e-dev` works on ARO-HCP PRs

On any PR targeting `main` in [Azure/ARO-HCP](https://github.com/Azure/ARO-HCP), a developer can trigger the CAPZ e2e test:

```
/test capz-e2e-dev
```

This is an **optional, non-blocking test** (`always_run: false`, `optional: true`). Timeout: 4 hours.

**Successful example:** [Azure/ARO-HCP#5484](https://github.com/Azure/ARO-HCP/pull/5484#issuecomment-5117015114)
**Prow log:** [pull-ci-Azure-ARO-HCP-main-capz-e2e-dev](https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/Azure_ARO-HCP/5484/pull-ci-Azure-ARO-HCP-main-capz-e2e-dev/2082425481839251456)

### Test flow

```
Step 1: Acquire DEV slot (slot-manager)
  └─ Leases shard subscription + MSI container RG
  
Step 2: Provision per-PR ARO-HCP DEV environment
  └─ SVC cluster, frontend, backend
  
Step 3: Create AKS management cluster
  └─ 1 node, Standard_D4s_v3, westus3

Step 4: Connect to DEV RP
  └─ Discover frontend via Istio VirtualService
  └─ Add NSG rule for AKS outbound IP
  └─ Register CI subscription with frontend

Step 5: Deploy CAPI + CAPZ + ASO + aro-mockup-proxy
  └─ Helm charts on AKS management cluster
  └─ Proxy configured with DEV_ENDPOINT pointing to frontend

Step 6: Create workload cluster
  └─ Apply generated HcpOpenShiftCluster manifests
  └─ ASO → proxy → DEV RP Frontend (creates real cluster)
  └─ Timeout: 120 min

Step 7: Verify workload cluster
  └─ Check nodes, cluster operators, health

Step 8: Delete workload cluster
  └─ Validate all K8s + Azure resources cleaned up

Step 9: Tear down
  └─ Collect logs, delete AKS RG, deprovision DEV env, release slot
```

### Resource leasing

| Resource | Mechanism |
|---|---|
| DEV shard subscription + MSI | slot-manager (`aro-hcp-lease-acquire/release`) |
| AKS management cluster | None (created/deleted per test run) |

### Implementation PRs (openshift/release)

- [#80110](https://github.com/openshift/release/pull/80110) — Added AKS-based e2e workflow
- [#80900](https://github.com/openshift/release/pull/80900) — Switched to slot-manager, enabled DEV RP proxy
- [#81966](https://github.com/openshift/release/pull/81966) — Updated cluster-api-installer branch

---

## 3. Architectural question: Shared DEV environment for parallel testing

### Current state

| Test suite | DEV environment | HCP clusters used | Pool |
|---|---|---|---|
| ARO-HCP tests | Per-PR (provisioned fresh) | Multiple | 50-slot pool |
| CAPZ e2e (`/test capz-e2e-dev`) | Per-PR (provisioned fresh) | 1 | 50-slot pool |
| Patrik's tests | Shared from main | 1 | 50-slot pool |

**Problem:** CAPZ and Patrik's tests each use only 1 HCP cluster but lease from the same 50-slot pool as ARO-HCP. This is wasteful and could cause contention.

### Proposed: CAPZ as a parallel step in ARO-HCP e2e

Instead of provisioning a separate DEV environment, CAPZ tests could reuse the DEV environment already provisioned by ARO-HCP tests:

```
ARO-HCP PR e2e workflow (current)
├── pre: provision DEV environment
├── test: ARO-HCP e2e tests
└── post: deprovision DEV environment

ARO-HCP PR e2e workflow (proposed)
├── pre: provision DEV environment
├── test (parallel):
│   ├── ARO-HCP e2e tests
│   └── CAPZ e2e test (reuses same DEV env)    ← NEW
└── post: deprovision DEV environment
```

**What CAPZ needs from the shared DEV environment:**
- Access to the DEV RP frontend endpoint (for the proxy to forward to)
- A leased shard subscription (for Azure resources)
- An AKS management cluster (could be shared or dedicated)

### Questions for the Architecture Office Hours

1. **Can CAPZ e2e tests share a DEV environment with ARO-HCP tests** instead of provisioning a separate one? The proxy architecture already supports this — CAPZ only needs an AKS cluster + access to the DEV RP frontend endpoint.

2. **If shared, how should we coordinate the lifecycle?** CAPZ tests could run as a parallel Prow step in the existing ARO-HCP e2e workflow, reusing the already-provisioned DEV environment.

3. **Should we right-size the slot-manager pool?** CAPZ and Patrik both need only 1 HCP cluster — a dedicated smaller pool would avoid contention with the main 50-slot pool.

4. **AKS management cluster leasing** — CAPZ creates a standalone AKS cluster as the CAPI management cluster. Should this use a lease mechanism (similar to slot-manager) to prevent resource conflicts between concurrent test runs?

### Benefits of shared DEV environment

- **Faster:** Skip 20-30 min DEV environment provisioning
- **Cheaper:** One less SVC cluster, frontend, backend per test run
- **Realistic:** Tests run against the same DEV environment as ARO-HCP, catching integration issues earlier
- **Simpler leasing:** CAPZ inherits the slot already leased by the ARO-HCP workflow
