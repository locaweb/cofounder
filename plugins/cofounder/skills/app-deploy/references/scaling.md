# Scaling Guide

## Table of Contents

- [Scaling Guide](#scaling-guide)
  - [Table of Contents](#table-of-contents)
  - [VM Plans](#vm-plans)
  - [Choosing the Right Plan](#choosing-the-right-plan)
    - [1. Runtime footprint](#1-runtime-footprint)
    - [2. Accessory sizing](#2-accessory-sizing)
    - [3. Environment purpose](#3-environment-purpose)
  - [Scaling the Web Tier](#scaling-the-web-tier)
  - [Scaling Workers](#scaling-workers)
  - [Scaling Accessories](#scaling-accessories)
  - [Disk Sizes](#disk-sizes)
    - [Choosing disk sizes](#choosing-disk-sizes)
  - [How Scaling Works](#how-scaling-works)

## VM Plans

Available plans (same options for `web_plan`, `workers_plan`, and accessory plans):

| Plan | vCPUs | Memory (GiB) |
|------|-------|--------------|
| `micro` | 1 | 1 |
| `small` | 1 | 2 |
| `medium` | 2 | 4 |
| `large` | 2 | 8 |
| `xlarge` | 4 | 16 |
| `2xlarge` | 8 | 32 |
| `4xlarge` | 16 | 64 |

## Choosing the Right Plan

Plan selection should consider three factors:

### 1. Runtime footprint

Different language runtimes (e.g., Go, Python, Node.js, Java) have varying baseline CPU and memory requirements. The specific framework, number of server workers, and application complexity also affect the resource footprint. Choose a plan that matches the actual resource consumption of your application, taking into account the target environment as well (for example, preview environments typically require fewer resources than production).

### 2. Accessory sizing

Each accessory (database, redis, etc.) has its own `plan` inside the `accessories` JSON input. Consider the expected workload for each:

- **Database (db)** (see [postgres-recipe.md -- Tuning with generate_pg_cmd.py](postgres-recipe.md#tuning-with-generate_pg_cmdpy) for plan-specific PostgreSQL tuning):
  - Small datasets (<1 GB), simple queries: `small` or `medium`
  - Medium datasets (1-10 GB), moderate queries: `medium` or `large`
  - Large datasets (>10 GB), complex queries or many connections: `large` or above
  - PostgreSQL benefits from available memory for OS page cache
- **Redis**: Typically `small` or `medium` is sufficient unless caching large datasets
- **Other accessories**: Size based on the specific service's requirements

### 3. Environment purpose

- **Preview/dev**: Use smaller plans (`micro`, `small`). These environments are for testing, not production traffic.
- **Production**: Size for expected load. Start with `medium` and scale up if needed.
- **Workers**: Depends on workload -- CPU-bound tasks (ML inference) need larger plans; I/O-bound tasks (queue processing) can use smaller plans.

## Scaling the Web Tier

The web tier is **vertical only** (single VM). Increase `web_plan` for more capacity:

```yaml
with:
  web_plan: "medium"  # upgrade from "small"
```

**Vertical scaling causes a restart with brief downtime.** The VM is stopped, resized, and started again. Plan scaling during low-traffic windows when possible.

## Scaling Workers

Workers scale **horizontally** by changing `workers_replicas`:

```yaml
with:
  workers_replicas: 3    # scale from 1 to 3 (0 = no workers)
  workers_plan: "small"
```

- `workers_replicas: 0` means no workers (disabled).
- Set to 1 or more to enable workers.

Scale up: re-deploy with a higher `workers_replicas`. New VMs are provisioned and containers deployed.

Scale down: re-deploy with a lower `workers_replicas`. Excess worker VMs are destroyed along with their public IPs, firewall rules, and static NAT mappings.

Workers can also scale vertically via `workers_plan`. **Vertical scaling of workers causes a restart with brief downtime** on the affected VMs.

## Scaling Accessories

Each accessory scales **vertically only** (single VM per accessory). Change the `plan` inside the `accessories` JSON:

```yaml
with:
  accessories: '[{"name":"db","plan":"large","disk_size_gb":100},{"name":"redis","plan":"medium","disk_size_gb":10}]'
```

**Vertical scaling causes a restart with brief downtime.** The accessory container will restart after the VM is resized. Ensure the application handles transient disconnections gracefully (e.g., database reconnection logic).

To add a new accessory, add an entry to the `accessories` JSON array and re-deploy. To remove an accessory, remove its entry from the JSON array -- the teardown of the removed accessory's resources happens automatically.

## Disk Sizes

| Disk | Input | Default | Attached to |
|------|-------|---------|-------------|
| Web disk | `web_disk_size_gb` | 20 GB | Web VM at `/data` |
| Accessory disks | `accessories` JSON `disk_size_gb` | 20 GB | Each accessory VM at `/data` |

Both web and accessory disks are mounted at `/data/` on their respective VMs. Always map Kamal volumes to a **subdirectory** of `/data/` (e.g., `/data/uploads`, `/data/pgdata`), never `/data/` root -- the ext4 filesystem creates `lost+found` at the mount root, which breaks containers that expect a clean directory. See [postgres-recipe.md -- Volume Mount](postgres-recipe.md#volume-mount-datapgdata-not-data) for the database example.

Disks can be **grown** by re-deploying with a larger value. **Shrinking is not supported** -- the workflow will fail with an error if you specify a smaller size than the current disk.

### Choosing disk sizes

- **Preview environments**: 20 GB default is usually sufficient
- **Production web disk**: Size based on expected upload volume. If the app stores user uploads, media files, etc., plan for growth.
- **Production database disk**: Size based on expected data volume plus headroom for WAL, temporary files, and vacuuming. A good rule of thumb is 2-3x the expected data size.
- **Redis / other accessories**: Typically small disks are sufficient unless persisting large datasets.

Example -- production with larger disks:

```yaml
with:
  web_disk_size_gb: 50
  accessories: '[{"name":"db","plan":"medium","disk_size_gb":100},{"name":"redis","plan":"small","disk_size_gb":10}]'
```

Workers are stateless and do not have data disks.

## How Scaling Works

Scaling happens through the normal deploy workflow -- there is no separate "scale" action. Re-run the deploy workflow with updated inputs (see [workflows.md -- Deploy Input Reference](workflows.md#deploy-input-reference) for all available inputs):

1. The provisioning script detects existing resources by name
2. For VMs: compares current service offering to desired; if different, stops the VM, scales it, and starts it again (expect brief downtime)
3. For disks: compares current size to desired; grows in-place if larger
4. For workers: creates new VMs if `workers_replicas` increased; destroys excess VMs if decreased
5. For accessories: adds new accessory VMs if new keys appear in the JSON; removes VMs if keys are removed
6. Kamal redeploys containers on all hosts (existing and new)

This means scaling and code deployment happen together in a single workflow run.
