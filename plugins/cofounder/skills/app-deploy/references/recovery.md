# Disaster Recovery

## Table of Contents

- [Overview](#overview)
- [How Data Protection Works](#how-data-protection-works)
- [When to Use Recovery](#when-to-use-recovery)
- [Pre-Flight Requirements](#pre-flight-requirements)
- [Recovery Procedure](#recovery-procedure)
  - [Caller Recovery Workflow](#caller-recovery-workflow)
  - [Monitoring the Recovery Run](#monitoring-the-recovery-run)
- [What Happens Under the Hood](#what-happens-under-the-hood)
- [Post-Recovery Verification](#post-recovery-verification)
- [Current Limitations](#current-limitations)
- [Creating Manual Snapshots](#creating-manual-snapshots)

## Overview

Every deployed environment has **automatic daily snapshots** of all data volumes (web disk and accessory disks). Recovery uses these snapshots to recreate data volumes in a new deployment, restoring the application to the state captured by the most recent snapshot.

Recovery is triggered by running the same deploy workflow with `recover: true`. The provisioning script replaces blank disk creation with disk-from-snapshot creation; everything else (VMs, networks, IPs, firewall rules) is provisioned normally.

## How Data Protection Works

The provisioning script creates a **daily snapshot policy** on every data volume (web disk and each accessory disk). These snapshots:

- Run at 06:00 UTC daily
- Keep the 3 most recent snapshots (older ones are automatically deleted)
- Are replicated across all available zones (both ZP01 and ZP02), so recovery can target either zone
- Are tagged with `locaweb-cloud-provision-id=<network_name>` for reliable lookup
- Are created as RECURRING type (policy-driven)

When an environment is [torn down](teardown.md), snapshot policies are deleted but **existing snapshots are preserved**. This means snapshots remain available for recovery even after the original deployment no longer exists.

## When to Use Recovery

- **After teardown**: You tore down an environment but need the data back.
- **VM or disk failure**: The deployment is lost but snapshots remain in the zone.
- **Data corruption**: Restore to a known-good state from a previous snapshot.

Recovery is **not** a substitute for application-level backups (e.g., `pg_dump`). It restores entire disk images, not individual rows or files. The restored data reflects the last snapshot time, not the moment of failure.

## Pre-Flight Requirements

The provisioning script runs mandatory pre-flight checks before proceeding with recovery. All three must pass:

| Check | What it verifies | Why |
|-------|-----------------|-----|
| No existing network | No network named `{repo}-{id}-{env}` in the target zone | Prevents recovering over a live deployment |
| No existing volumes | No web or accessory data disks in the target zone | Same as above -- forces explicit teardown first |
| Snapshots exist | A snapshot in `BackedUp` state exists for every expected volume (web + each accessory) | Cannot recover without data to restore |

If any check fails, the workflow exits with an error message explaining what's wrong.

**Practical implication:** If the original deployment still exists in the target zone, you must [tear it down](teardown.md) before running recovery. Teardown deletes volumes but preserves snapshots, so recovery can proceed afterward.

## Recovery Procedure

Trigger the deploy workflow with `recover: true`. The `zone` input determines where the recovered deployment will be created. Snapshot policies replicate snapshots across all available zones, so snapshots are available in either zone regardless of where the original deployment lived.

The provisioning script's [pre-flight checks](#pre-flight-requirements) will verify that no existing deployment conflicts with recovery and that snapshots are present. If anything is wrong, the workflow fails with a clear error -- there's no need to check manually beforehand.

### Caller Recovery Workflow

Recovery uses the existing deploy workflow -- no separate workflow is needed. Simply add `recover: true` to the infra job inputs:

```yaml
# Trigger via workflow_dispatch, or modify the existing workflow temporarily
jobs:
  infra:
    uses: gmautner/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"
      zone: "ZP01"                                            # Zone for the recovered deployment (either zone works)
      accessories: '[{"name":"db","plan":"medium","disk_size_gb":20}]'
      recover: true                                           # Enable disaster recovery
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}

  deploy:
    needs: infra
    # ... same deploy job as the normal workflow
```

All other inputs (`web_plan`, `web_disk_size_gb`, `workers_replicas`, etc.) work the same. The disk size inputs are ignored during recovery because disk sizes are determined by the snapshots.

**Via GitHub Actions UI:** If the workflow uses `workflow_dispatch`, check the "Recover from snapshots" checkbox in the GitHub Actions run dialog.

**Via CLI:**

```bash
gh workflow run deploy-preview.yml -f recover=true
```

### Monitoring the Recovery Run

```bash
# Watch the run
gh run list --workflow=deploy-preview.yml --limit=5
gh run watch <run-id>
```

Give the user a direct link to the job in the GitHub UI:

```bash
echo "$(gh repo view --json url -q .url)/actions/runs/<run-id>/job/$(gh run view <run-id> --json jobs -q '.jobs[0].databaseId')"
```

When `recover: true`, the workflow **skips infrastructure caching** -- it always runs the full provisioning script to ensure snapshots are properly restored.

## What Happens Under the Hood

The recovery flow reuses the normal provisioning pipeline. Only the disk creation step differs:

```
Normal:   Network → VMs → IPs → Firewall → Blank disks → Snapshot policies
Recovery: Network → VMs → IPs → Firewall → Disks from snapshots → Snapshot policies
```

Step by step:

1. **Pre-flight checks** -- verifies no existing deployment and that snapshots exist (see [Pre-Flight Requirements](#pre-flight-requirements))
2. **Snapshot discovery** -- finds the most recent snapshot for each expected volume (`{network_name}-webdata`, `{network_name}-{accessory}data`) in the target zone. Both MANUAL and RECURRING snapshot types are considered; the most recent `BackedUp` snapshot wins.
3. **Normal provisioning** -- creates the network, VMs, public IPs, static NAT, and firewall rules exactly as a fresh deployment.
4. **Disk creation from snapshots** -- instead of creating blank disks, creates volumes from the discovered snapshots. Each volume is tagged with `locaweb-cloud-provision-id` and attached to its VM.
5. **Snapshot policies** -- new daily snapshot policies are created on the recovered volumes, maintaining the same data protection as a fresh deployment.
6. **Cloud-init compatibility** -- the VM userdata scripts check `blkid` before formatting disks. Since recovered volumes already have ext4 filesystems with data, formatting is skipped and data is preserved as-is.
7. **Kamal deploy** -- the deploy job runs `kamal setup` on the fresh infrastructure, deploying the application. The app starts with the recovered data volumes mounted.

## Post-Recovery Verification

After the workflow succeeds:

### 1. Health check

```bash
curl -s -o /dev/null -w "%{http_code}" https://<web_ip>.nip.io/up
```

### 2. Verify recovered data

SSH into the VMs and check that data is present. See [operations.md](operations.md) for SSH access and container debugging commands.

For a database accessory:

```bash
# SSH into the database VM
ssh -i ~/.ssh/<repo-name> root@<accessories.db.ip>

# Check the data
docker exec -it <repo-name>-db psql -U postgres -c "SELECT count(*) FROM <table>;"
```

For the web disk:

```bash
# SSH into the web VM
ssh -i ~/.ssh/<repo-name> root@<web_ip>

# Check uploaded files exist
ls -la /data/uploads/    # or whatever subdirectory the app uses
```

### 3. Verify snapshot policies

New snapshot policies are created automatically on recovered volumes. No manual action needed -- the recovered deployment has the same daily snapshot protection as a fresh one.

## Current Limitations

- **No existing deployment in target zone**: If the deployment still exists in the target zone, you must tear it down first. The pre-flight checks enforce this to prevent data loss. Recovery can target either zone -- snapshot policies replicate across all available zones.
- **Recovery point is the last snapshot**: Data written after the most recent snapshot is lost. The daily schedule means up to ~24 hours of data loss in the worst case (RPO). For lower RPO, create manual snapshots before planned operations.
- **Disk sizes match the snapshot**: The `web_disk_size_gb` and accessory `disk_size_gb` inputs are ignored during recovery -- the recovered volume inherits the size of the source snapshot's volume.
- **All volumes must have snapshots**: Recovery requires a snapshot for every expected volume (web + each accessory). If any snapshot is missing, recovery fails at pre-flight.

## Creating Manual Snapshots

Daily snapshots run at 06:00 UTC. To create an immediate snapshot before a risky operation or planned teardown, use the CloudStack dashboard or API directly. Manual snapshots are also considered during recovery (both MANUAL and RECURRING types are searched).

The provisioning script does not provide a built-in manual snapshot command -- use the CloudStack UI at [painel-cloud.locaweb.com.br](https://painel-cloud.locaweb.com.br/) to create snapshots from the Volumes section.
