# GitHub Actions
The configuration is in [.github/workflows/crons.yml](https://github.com/stolostron/cluster-api-installer/blob/main/.github/workflows/crons.yml), and the cron job runs once a week (only from the `main` branch):
```yaml
on:
  schedule:
    - cron: "24 0 * * 3"
```
There is a job specified per branch, e.g., for the `release-2.8` branch:
```yaml
jobs:
  call-sync-release-2_8:
    permissions:
      contents: write
      pull-requests: write
    uses: ./.github/workflows/sync-providers.yaml
    with:
      dst-branch: "release-2.8"
    secrets:
      personal_access_token: ${{ secrets.GITHUB_TOKEN }}
```

You can also manually trigger the workflow from the **Actions** menu on GitHub: [Manual Workflow](https://github.com/stolostron/cluster-api-installer/actions/workflows/manual.yaml):
 * Click on `Run workflow`
 * and then select the `Branch to sync`.

