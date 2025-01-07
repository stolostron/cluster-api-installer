# cluster-api-installer

## For cluster-api
* run:
   * `make` this will do: ```
```

* or you can speed-up the testing (skip `git pull ...`) using `(export SKIP_CLONE=true; make) `
* or you can update release versions by `make release-chart` in `charts/*/Chart.yaml` and `charts/*/values.yaml`
* or you can check the deployment of charts by:
   * `make test-charts-crc`
   * `(export CRC_DELETE=true; make test-charts-crc ) # with crc delete --force`
