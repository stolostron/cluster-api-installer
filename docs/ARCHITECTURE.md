# Architecture

This document describes the architecture of `cluster-api-installer`: how it is
structured, how the pieces fit together, and the design decisions behind them.
It is the architectural map; operational detail (every Make target, every
environment variable, step-by-step guides) lives in [../README.md](../README.md)
and the task guides under [../doc/](../doc).

> **Note on `doc/` vs `docs/`.** Existing task-oriented guides live in the
> [`doc/`](../doc) directory (singular). This architectural overview lives in
> `docs/` (plural), following the `docs/ARCHITECTURE.md` convention. Both are
> current; see [../AGENTS.md](../AGENTS.md) for the full index.

## Purpose

`cluster-api-installer` produces the **Helm charts** used to install Cluster API
(CAPI) and its infrastructure providers as components of the MultiClusterEngine
(MCE) operator on OpenShift. It is not a runtime component — it is a build system
that takes upstream provider manifests and turns them into OpenShift-ready,
versioned charts, together with the scripts that deploy and smoke-test them.

Supported providers:

- **CAPA** — Cluster API Provider AWS
- **CAPZ** — Cluster API Provider Azure (drives ARO HCP)
- **CAPM3** — Cluster API Provider Metal3
- **OpenShift-Assisted** — Cluster API Provider OpenShift-Assisted

A key design decision: OpenShift already ships a certificate-serving service, so
the charts are transformed to use the OpenShift `service-ca` (via
`service.beta.openshift.io/inject-cabundle` and `serving-cert-secret-name`
annotations) instead of the upstream `cert-manager` `Certificate`/`Issuer`
resources.

## High-level flow

```
upstream provider repo (pinned branch)
        │  scripts/build.sh  (git clone → src/$PROJECT.yaml)
        ▼
   raw manifests  ──▶  Kustomize transform (config/$PROJECT)
        │                    scripts/sync2chart.sh
        ▼
   charts/$PROJECT/{crds,templates} + versioned Chart.yaml
        │
        ▼
   helm install (scripts/deploy-charts*.sh)  ──▶  OpenShift / k8s / Kind
```

The build is driven by `make`; deployment and testing are driven by the scripts
in [`scripts/`](../scripts).

## The sync-and-transform pipeline

The heart of the repo is the chart-generation pipeline, orchestrated by the
top-level [`Makefile`](../Makefile) which delegates per-provider work to
[`charts/Makefile`](../charts/Makefile). For each provider `$PROJECT`:

1. **Clone** — [`scripts/build.sh`](../scripts/build.sh) clones
   `$ORGREPO/$PROJECT` at the pinned `$BRANCH` into a temporary `out/` directory.
   Set `SKIP_CLONE=true` to reuse an existing checkout while iterating.
2. **Extract** — the upstream `config/` is rendered to a source manifest,
   captured under [`src/$PROJECT.yaml`](../src) (the pre-transformation snapshot,
   useful for diffing what upstream produced).
3. **Transform** — [`scripts/sync2chart.sh`](../scripts/sync2chart.sh) applies
   the Kustomize configuration in `config/$PROJECT` to rewrite the manifests into
   Helm chart templates, writing `charts/$PROJECT/crds` and
   `charts/$PROJECT/templates`.
4. **Version** — `charts/$PROJECT/Chart.yaml` and the controller `image.tag` in
   `values.yaml` are stamped from the version/branch inputs.
5. **Inspect** — `git status` shows the resulting diff in `src/` and
   `charts/$PROJECT/`.

Charts under `charts/*/crds` and `charts/*/templates` are therefore **generated
artifacts** — they are edited by changing the Kustomize config and re-running the
build, not by hand.

## Version and branch pinning

All provider versions and source branches are declared in
[`charts/Makefile`](../charts/Makefile):

| Variable | Meaning |
|----------|---------|
| `OCP_VERSION` | Base for controller image tag and chart version (core/Metal3) |
| `MCE_VERSION` | Chart/app version for MCE-tracked providers (CAPA/CAPZ) |
| `*_BRANCH` (e.g. `CAPZ_BRANCH`, `CAPA_BRANCH`, `METAL3_BRANCH`) | Upstream branch to sync each provider from |
| `*_ORGREPO` (`DEFAULT_`, `STOLOSTRON_`, `OPENSHIFT_ASSISTED_`) | Source repository URLs |

Helper functions (`get-tag-from-branch`, `get-version-from-branch`) derive image
tags and chart versions from branch names (`release-*`, `backplane-*`, `main`).

## Chart flavors

The same providers are emitted in three flavors so the charts can target
different environments. Each flavor pairs a `config*` transform directory with a
`charts/*` output directory and is selected by the deploy scripts via a chart
suffix:

| Flavor | Config dir | Chart suffix | Target |
|--------|-----------|--------------|--------|
| OpenShift (default) | [`config/`](../config) | *(none)* | OpenShift / CRC — uses the OpenShift cert service |
| Kubernetes | [`config-k8s/`](../config-k8s) | `-k8s` | Plain Kubernetes / MCE namespace |
| Kind | [`config-kind/`](../config-kind) | `-kind` | Local Kind clusters for development |

The transforms differ in namespace handling, certificate wiring, and image
settings appropriate to each target. See any
[`config/*/kustomization.yaml`](../config/cluster-api/kustomization.yaml) for the
patch set (namespace deletion, cert-manager → OpenShift cert-service rewrite,
Deployment image/command templating, webhook service annotations).

## Deployment paths

Two independent ways to get the providers running are supported:

1. **Direct Helm install** — [`scripts/deploy-charts.sh`](../scripts/deploy-charts.sh)
   (with `deploy-charts-crc.sh`, `deploy-charts-kind-capz.sh`,
   `deploy-charts-k8s-capz.sh` wrappers). Chooses the chart flavor from
   `USE_KIND` / `USE_K8S` / OpenShift context, optionally creates a Kind cluster
   via [`scripts/setup-kind-cluster.sh`](../scripts/setup-kind-cluster.sh), and
   `helm install`s the charts. This mirrors how MCE consumes the charts.
2. **Cluster API Operator** — [`cluster-api-operator/`](../cluster-api-operator)
   plus [`scripts/deploy-operator.sh`](../scripts/deploy-operator.sh) install the
   upstream `cluster-api-operator` and apply `CoreProvider` /
   `InfrastructureProvider` custom resources. See
   [../cluster-api-operator/README.md](../cluster-api-operator/README.md).

Both paths depend on `cert-manager` (Kind/k8s) or the OpenShift cert service
(OpenShift) being present for webhook certificates.

## Cluster provisioning scripts (ARO / ROSA HCP)

Beyond installing the controllers, the repo carries scripts and templates that
exercise them by provisioning managed clusters:

- [`scripts/aro-hcp/`](../scripts/aro-hcp) — ARO HCP via CAPZ + Azure Service
  Operator (ASO): `gen.sh`/`aro-hcp-create*.sh` render the `aro-*` templates
  (identities, role assignments, ASO resources) for a given API version.
- [`scripts/rosa-hcp/`](../scripts/rosa-hcp) — ROSA HCP via CAPA: `gen.sh` and
  `rosa-template.yaml` / `secrets-template.yaml`.

These are the source of truth behind the ARO/ROSA guides in [`doc/`](../doc).

## Supporting components

- [`kustomize-plugins/transformers/envsubst`](../kustomize-plugins) — a custom
  Kustomize transformer that substitutes environment variables into manifests
  during the sync (used together with per-provider `env` files in `config/`).
- [`mce-capi-webhook-config/`](../mce-capi-webhook-config) — a standalone Go
  module implementing an MCE CAPI mutating webhook, with its own `Dockerfile`,
  build, and Konflux/Tekton pipelines in [`.tekton/`](../.tekton).
- [`aro-mockup-proxy/`](../aro-mockup-proxy) — a Go ARM mock/proxy used to test
  ARO HCP flows without a live Azure backend.

## Build environments

The build tools (kustomize, yq, helm, clusterctl) are pinned and installed into
`hack/tools` by the [`Makefile`](../Makefile). Two build modes:

- **Local** — `make` runs the sync directly on the host.
- **Containerized** — `make build-docker` runs the same targets inside a Go
  container for a reproducible environment (`CONTAINER_ENGINE` selects
  docker/podman). Single charts: `make build-docker-<project>-chart`.

## CI/CD

- [`.github/workflows/`](../.github/workflows) — a weekly `crons.yml` job invokes
  `sync-providers.yaml` to regenerate charts per release branch and open PRs;
  `manual.yaml` triggers the same on demand; other workflows lint/test the Kind
  CAPA path and the webhook config. See [../doc/GitHub-Actions.md](../doc/GitHub-Actions.md).
- [`.tekton/`](../.tekton) — Konflux pipelines building and pushing the
  `mce-capi-webhook-config` image.
- Dependency updates are automated via [`renovate.json`](../renovate.json).

## Repository layout

```
.
├── charts/               # Generated Helm charts (core + providers) + charts/Makefile
│   ├── cluster-api*/      #   core CAPI (OpenShift / -k8s / -kind flavors)
│   └── cluster-api-provider-*/  #   AWS, Azure, Metal3, OpenShift-Assisted
├── config/               # Kustomize transforms — OpenShift (default) flavor
├── config-k8s/           # Kustomize transforms — plain Kubernetes flavor
├── config-kind/          # Kustomize transforms — Kind flavor
├── src/                  # Pre-transformation upstream manifest snapshots
├── scripts/              # Build (build.sh, sync2chart.sh) + deploy + aro-hcp/ rosa-hcp/
├── cluster-api-operator/ # CoreProvider / InfrastructureProvider CRs + deploy path
├── kustomize-plugins/    # Custom Kustomize transformers (envsubst)
├── mce-capi-webhook-config/  # Standalone MCE CAPI mutating webhook (Go module)
├── aro-mockup-proxy/     # ARM mock/proxy for ARO HCP testing (Go)
├── doc/                  # Task-oriented guides (ARO, ROSA, adding providers, CI)
├── docs/                 # This architectural overview
├── .github/workflows/    # Sync/CI GitHub Actions
├── .tekton/              # Konflux/Tekton pipelines for the webhook image
├── Makefile              # Top-level build entry point (delegates to charts/Makefile)
├── AGENTS.md             # Index of context docs for AI agents and new contributors
├── README.md             # Overview and build/test commands
└── OWNERS                # Approvers and reviewers
```

## Related documentation

- [../README.md](../README.md) — overview and build/test commands
- [../AGENTS.md](../AGENTS.md) — documentation index
- [../doc/Adding-NewProvider.md](../doc/Adding-NewProvider.md) — adding a provider
- [../doc/GitHub-Actions.md](../doc/GitHub-Actions.md) — sync workflows / CI
- [../cluster-api-operator/README.md](../cluster-api-operator/README.md) — operator-based deployment
