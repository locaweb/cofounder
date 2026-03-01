# Teardown Guide

## Table of Contents

- [Teardown Workflow](#teardown-workflow)
- [Caller Teardown Workflow](#caller-teardown-workflow)
- [Inferring Zone and env_name](#inferring-zone-and-env_name)
- [Reading Last Run Outputs](#reading-last-run-outputs)
- [What Teardown Destroys](#what-teardown-destroys)
- [Important Notes](#important-notes)

## Teardown Workflow

The teardown workflow requires only two inputs:

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| `env_name` | string | no (default: `preview`) | Environment name to tear down |
| `zone` | string | yes | CloudStack zone where the environment is deployed |

And two secrets:

| Secret | Required |
|--------|----------|
| `CLOUDSTACK_API_KEY` | yes |
| `CLOUDSTACK_SECRET_KEY` | yes |

## Caller Teardown Workflow

```yaml
# .github/workflows/teardown-preview.yml
name: Teardown Preview
on:
  workflow_dispatch:

jobs:
  teardown:
    uses: gmautner/locaweb-cloud-deploy/.github/workflows/teardown.yml@v0
    with:
      env_name: "preview"
      zone: "ZP01"
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
```

Create one teardown workflow per environment. For example:
- `teardown-preview.yml` with `env_name: "preview"`, `zone: "ZP01"`
- `teardown-production.yml` with `env_name: "production"`, `zone: "ZP01"`

### Monitoring the teardown run

```bash
gh run list --workflow=teardown-preview.yml --limit=5
gh run watch <run-id>
```

Give the user a direct link to the job in the GitHub UI:

```bash
echo "$(gh repo view --json url -q .url)/actions/runs/<run-id>/job/$(gh run view <run-id> --json jobs -q '.jobs[0].databaseId')"
```

## Inferring Zone and env_name

When tearing down an environment and the zone/env_name are not known, infer them from the existing deploy workflow:

1. **Read the committed deploy workflow** (e.g., `.github/workflows/deploy-preview.yml`):
   - `env_name` is in the `with:` block (e.g., `env_name: "preview"`)
   - `zone` is in the `with:` block (e.g., `zone: "ZP01"`)

2. **Confirm by checking the last run** using the GitHub CLI:

```bash
# List recent runs of the deploy workflow
gh run list --workflow=deploy-preview.yml --limit=5

# View a specific run's details (includes inputs)
gh run view <run-id>

# Download the provision-output artifact to see IPs (clean first to avoid stale data)
rm -rf /tmp/provision-output
gh run download <run-id> --name provision-output --dir /tmp/provision-output
cat /tmp/provision-output/provision-output.json
```

3. **Decode provision-output.json** -- the artifact contains:

```json
{
  "web_ip": "200.234.x.x",
  "worker_ips": ["200.234.y.y"],
  "accessories": {
    "db": {
      "ip": "200.234.z.z",
      "internal_ip": "10.1.1.x"
    }
  }
}
```

These IPs confirm which deployment is active and help verify the environment before teardown.

## Reading Last Run Outputs

To retrieve deployment information from a previous run:

```bash
# Find the latest successful deploy run
gh run list --workflow=deploy-preview.yml --status=success --limit=1

# Get the run ID and download its artifact (clean first to avoid stale data)
rm -rf /tmp/output
gh run download <run-id> --name provision-output --dir /tmp/output
cat /tmp/output/provision-output.json
```

The step summary (visible in the GitHub UI) also shows:
- Infrastructure table: resource type and public IP for each VM
- Deployment summary: commit SHA, image tag, app URL, health check URL
- If a domain was configured: the domain name and the IP to point DNS at

## What Teardown Destroys

The teardown script destroys resources in reverse creation order:

1. **Snapshot policies** on all data volumes (the policies are deleted, but **existing snapshots are preserved** -- they remain available for potential future disaster recovery)
2. **Data volumes** (web disk, accessory disks) -- detached then deleted
3. **Static NAT mappings** on all public IPs
4. **Firewall rules** on all public IPs
5. **Public IPs** (released)
6. **All VMs** (web, workers, accessories -- destroyed with expunge)
7. **The isolated network** (after 5s wait for VM expunge)
8. **The SSH key pair**

All `cmk` failures during teardown are treated as non-fatal warnings (resources may already be partially deleted).

## Important Notes

- **zone must match**: The teardown `zone` must match the zone where the environment was deployed. Resources in the wrong zone will not be found.
- **env_name must match**: The teardown `env_name` must match the deploy `env_name` exactly. The resource naming pattern is `{repo-name}-{repository-id}-{env_name}`.
- **Data disks are permanently deleted**: Teardown deletes data volumes (web and accessory disks). However, **snapshots taken before teardown are preserved** and remain in the CloudStack account. These snapshots may be useful for future disaster recovery workflows.
- **Safe to re-run**: If some resources are already deleted (e.g., partial teardown), the script continues without failing.
- **Shared concurrency group**: Teardown shares the `deploy-{repository}-{env_name}` concurrency group with the deploy workflow, so a teardown cannot run while a deploy is in progress (and vice versa).
