# cluster-api-installer

## Introduction

The Cluster-api-installer repository creates Helm charts for Cluster-API (CAPI) and its providers, such as Cluster-API-provider-AWS (CAPA), designed for deployment on OpenShift clusters. The MultiClusterEngine operator utilizes these Helm charts to deploy CAPI and CAPA as components of the MultiClusterEngine. For the upcoming release, the Cluster-api-installer repository will include Helm charts for additional Cluster-API providers, such as Cluster-API-provider-Azure (CAPZ) and Cluster-API-provider-Metal3 (CAPM).

CAPI components require the cert-manager operator to generate the necessary certificates. The Cluster-api-installer modifies the CAPI Helm charts to leverage the cert-serve-service (certificate service) that already exists within the OpenShift cluster, instead of relying on the cert-manager operator.

## How it works
The cluster-api-installer synch the changes happened in the openshift/cluser-api and openshift/cluster-api-provider-aws repos to the chart directory 
 * Core CAPI provider → `charts/cluster-api`
 * CAPA - AWS provider → `charts/cluster-api-provider-aws`

The synchronization process synchronizes the Kubernetes deployment and creates a Helm chart (used for the Backplane Operator).

The synchronizations are defined in `charts/Makefile`:
```make
OCP_VERSION ?= 4.19
BRANCH ?= master
ORGREPO ?= https://github.com/openshift
```

Where:
  * `OCP_VERSION` ... the base for:
    * Controller image version - used in the Kubernetes deployment
    * Helm chart version (version in Chart.yaml)
  * `BRANCH` ... the branch from which we will sync the changes
  * `ORGREPO` ... source repository URL

Then (for `PROJECT` in `cluster-api` `cluster-api-provider-aws`):
 1. The Git repository `$ORGREPO/$PROJECT` will be cloned into `out/$PROJECT`, and the `$BRANCH` will be checked out into the `out` temporary directory.
 2. The `src/$PROJECT.yaml` file with the source objects (before transformation - see below) will be created.
 3. The synchronization of CRDs and Helm chart templates will begin, and the necessary files will be created/updated in the `charts/$PROJECT/crds` and `charts/$PROJECT/templates` directories.
    * Synchronization is performed using Kustomize transformations defined in the `config/$PROJECT` folder.
 4. The version in `charts/$PROJECT/Chart.yaml` and the `image.tag` in `charts/cluster-api/values.yaml` will be updated based on `$OCP_VERSION`.
 5. You can view the changes (using `git status`) in:
    * The sources before transformation - in the `src/$PROJECT.yaml` file.
    * The target Helm charts in the `charts/$PROJECT` directory.

There are also [GitHub workflows](./doc/GitHub-Actions.md) for synchronization.  
See [this documentation](./doc/Adding-NewProvider.md) if you want to add a new provider.

### Commands
* To sync:
  * `make` - This will sync all charts.
    * You can view the changes using `git status` after a successful command.
    * To speed up testing (skip `git pull ...`), use:
      ```sh
      export SKIP_CLONE=true; make
      ```
  * To use Docker, run:
    ```sh
    make build-docker
    ```
    * The result should be the same as `make`.
    * A Docker container is used for a more unified build environment.
    * Use this if you encounter issues with the standard `make` command.
* To check chart deployment:
  ```sh
   make test-charts-crc
  ```
  * To delete CRC before testing:
    ```sh
    export CRC_DELETE=true; make test-charts-crc
    ```
* To clean all temporary files:
  ```sh
  make clean
  ```


