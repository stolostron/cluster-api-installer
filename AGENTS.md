# AGENTS.md

Entry point for AI coding agents (and new humans) working in this repository.
This file is a **table of contents**, not a manual — it points to the
authoritative docs rather than duplicating them. Read the linked document for
detail before making changes.

> This repo does not yet ship tool-specific agent guideline files
> (`CLAUDE.md` / `GEMINI.md`). `AGENTS.md` is the vendor-neutral index per the
> [agents.md](https://agents.md) convention; when those files are added they
> should be linked from here.

## What this repo is

`cluster-api-installer` builds **Helm charts** for Cluster API (CAPI) core and
its infrastructure providers (AWS/CAPA, Azure/CAPZ, Metal3/CAPM3, and
OpenShift-Assisted), packaged for deployment on OpenShift by the
MultiClusterEngine (MCE) operator. It is primarily a **sync-and-transform build
system** — it pulls manifests from upstream provider repos, rewrites them with
Kustomize, and emits versioned charts — plus the scripts used to deploy and
exercise those charts.

| Fact | Value |
|------|-------|
| Charts produced | [`charts/`](charts) (OpenShift, `-k8s`, and `-kind` flavors) |
| Build entry point | [`Makefile`](Makefile) → [`charts/Makefile`](charts/Makefile) |
| Provider versions / branches | pinned in [`charts/Makefile`](charts/Makefile) |
| Sync + transform scripts | [`scripts/`](scripts) (`build.sh`, `sync2chart.sh`) |
| Kustomize transforms | [`config/`](config), [`config-k8s/`](config-k8s), [`config-kind/`](config-kind) |
| Tooling | kustomize, yq, helm, clusterctl (installed via `Makefile`) |
| Ownership | [`OWNERS`](OWNERS) |

## Start here

| Document | What it covers |
|----------|----------------|
| [README.md](README.md) | Overview, how the sync works, build/test commands |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture: sync pipeline, chart flavors, transforms, deploy paths, repo layout |
| [doc/](doc) | Task-oriented guides (ARO/CAPZ, ROSA HCP, adding a provider, CI) |
| [OWNERS](OWNERS) | Approvers and reviewers |

## Working guidelines for agents

- **Charts are generated, not hand-edited.** Files under `charts/*/crds` and
  `charts/*/templates` are produced by the sync. To change chart output, edit the
  Kustomize config in `config/$PROJECT` (or `config-k8s` / `config-kind`) and
  re-run the build — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
- **Provider versions live in [`charts/Makefile`](charts/Makefile)** (`OCP_VERSION`,
  `MCE_VERSION`, per-provider `*_BRANCH` / `*_ORGREPO`). Bump there, not in the
  generated `Chart.yaml`.
- **Rebuild before committing chart changes:** `make` (or `make build-docker` for
  a containerized, reproducible build). Inspect the result with `git status`.
- **Lint charts:** `make lint`.
- **Adding a provider:** follow [doc/Adding-NewProvider.md](doc/Adding-NewProvider.md).
- **Git workflow:** feature branch + PR onto `main`; never commit to `main`.

## Reference documentation

- [doc/ARO-capz.md](doc/ARO-capz.md) — ARO HCP via CAPZ
- [doc/ARO-capz-mce.md](doc/ARO-capz-mce.md) — ARO HCP via CAPZ on MCE
- [doc/ARO-create-resources-using-aso.md](doc/ARO-create-resources-using-aso.md) — creating Azure resources with ASO
- [doc/aro-hcp-api-v1api20251223preview-migration.md](doc/aro-hcp-api-v1api20251223preview-migration.md) — ARO HCP API migration
- [doc/Create-rosa-hcp.md](doc/Create-rosa-hcp.md) / [doc/multi-account-rosa-hcp.md](doc/multi-account-rosa-hcp.md) — ROSA HCP
- [doc/Enable_iam_roles_capa.md](doc/Enable_iam_roles_capa.md) — CAPA IAM roles
- [doc/Adding-NewProvider.md](doc/Adding-NewProvider.md) — adding a new provider
- [doc/GitHub-Actions.md](doc/GitHub-Actions.md) — sync workflows / CI
- [cluster-api-operator/README.md](cluster-api-operator/README.md) — deploying via the Cluster API Operator
- [charts/cluster-api/README.md](charts/cluster-api/README.md) — CAPI core chart notes
