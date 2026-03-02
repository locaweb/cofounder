# supabase/postgres Accessory Recipe

Hard-won knowledge about deploying the `supabase/postgres` image as a Kamal accessory. Every section documents a non-obvious behavior that was discovered through iteration. Follow this recipe exactly to avoid re-learning these lessons.

## Table of Contents

- [Complete Accessory Recipe](#complete-accessory-recipe)
- [The `-D /etc/postgresql` Flag](#the--d-etcpostgresql-flag)
- [Volume Mount: `/data/pgdata`, Not `/data/`](#volume-mount-datapgdata-not-data)
- [Container Env: Only `POSTGRES_PASSWORD`](#container-env-only-postgres_password)
- [DATABASE\_URL as a Static GitHub Secret](#database_url-as-a-static-github-secret)
- [Tuning with `generate_pg_cmd.py`](#tuning-with-generate_pg_cmdpy)
- [Plan-to-RAM Mapping Table](#plan-to-ram-mapping-table)
- [Sync with Workflow](#sync-with-workflow)

## Complete Accessory Recipe

The `deploy.yml` snippet for the database accessory:

```yaml
accessories:
  db:
    image: supabase/postgres:17.6.1.093
    # host goes in the destination file (e.g. deploy.preview.yml)
    port: "5432:5432"
    cmd: "postgres -D /etc/postgresql -c shared_buffers=1GB -c effective_cache_size=3GB -c work_mem=10MB -c maintenance_work_mem=256MB -c max_connections=100"
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - /data/pgdata:/var/lib/postgresql/data
```

The destination file sets the host IP:

```yaml
# config/deploy.preview.yml
accessories:
  db:
    host: <%= ENV['INFRA_DB_IP'] %>
```

The `.kamal/secrets.<destination>` file (agent-owned, one per environment, app secrets only -- registry is handled by the workflow):

```
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=$DATABASE_URL
```

The `cmd` values shown above are for a `medium` plan (4 GiB RAM). Use `generate_pg_cmd.py` to compute plan-specific tuning -- see [Tuning with `generate_pg_cmd.py`](#tuning-with-generate_pg_cmdpy).

## The `-D /etc/postgresql` Flag

Standard postgres Docker images use `-D /var/lib/postgresql/data` for the config directory. The `supabase/postgres` image is different: its configuration lives at `/etc/postgresql` and the data directory is separate.

The `cmd` **must** include `-D /etc/postgresql`:

```
postgres -D /etc/postgresql -c shared_buffers=1GB ...
```

Without this flag, postgres will look for configuration in the wrong path and fail to start.

## Volume Mount: `/data/pgdata`, Not `/data/`

The host disk is mounted at `/data/` by the workflow. The ext4 filesystem creates a `lost+found` directory at the mount root. PostgreSQL's `initdb` fails if the data directory is not empty.

Always bind-mount a **subdirectory**:

```yaml
accessories:
  db:
    directories:
      - /data/pgdata:/var/lib/postgresql/data   # CORRECT -- clean subdirectory
      # - /data:/var/lib/postgresql/data         # WRONG -- lost+found breaks initdb
```

## Container Env: Only `POSTGRES_PASSWORD`

The `supabase/postgres` image only accepts `POSTGRES_PASSWORD` as a container environment variable. Do **not** pass `POSTGRES_USER` or `POSTGRES_DB` -- the image's internal init scripts bootstrap with user `postgres` and database `postgres` by default, and injecting these vars conflicts with that process.

```yaml
# CORRECT
accessories:
  db:
    env:
      secret:
        - POSTGRES_PASSWORD

# WRONG -- will conflict with supabase/postgres init
accessories:
  db:
    env:
      clear:
        POSTGRES_USER: myuser      # DO NOT
        POSTGRES_DB: mydb          # DO NOT
      secret:
        - POSTGRES_PASSWORD
```

## DATABASE_URL as a Static GitHub Secret

The application containers receive `DATABASE_URL` as a separate secret from the Postgres container's `POSTGRES_PASSWORD`. The user writes `DATABASE_URL` once as a GitHub Secret at setup time:

```
postgres://postgres:mypassword@db:5432/postgres
```

Breakdown:
- **User**: always `postgres` (the image bootstraps this; see above)
- **Database**: always `postgres`
- **Host**: `db` -- matches the accessory name. CloudStack DNS resolves it to the accessory VM's internal (private) IP within the isolated network
- **Port**: `5432`

No runtime composition is needed. The hostname `db` is deterministic (it matches the accessory name and VM name), and the password is known at setup time. The workflow never sees, composes, or passes through `DATABASE_URL` -- it flows from GitHub Secret to runner environment to Kamal to container.

The corresponding GitHub Secrets the user must create:

```
POSTGRES_PASSWORD=<random password>
DATABASE_URL=postgres://postgres:<same password>@db:5432/postgres
```

## Tuning with `generate_pg_cmd.py`

The script at `scripts/generate_pg_cmd.py` computes plan-appropriate PostgreSQL tuning parameters. It encodes the plan-to-RAM mapping and produces a complete `postgres` command string.

Usage:

```bash
python3 scripts/generate_pg_cmd.py --plan <plan>
```

Example output for `--plan medium`:

```
postgres -D /etc/postgresql -c shared_buffers=1GB -c effective_cache_size=3GB -c work_mem=10MB -c maintenance_work_mem=256MB -c max_connections=100
```

The agent runs this script with the chosen plan and uses the output as the value for `accessories.db.cmd` in `deploy.yml`.

### Tuning algorithm

The script computes five PostgreSQL parameters from the plan's RAM:

| Parameter | Formula | Notes |
|---|---|---|
| `shared_buffers` | RAM / 4 | Main memory cache for table/index data |
| `effective_cache_size` | RAM * 3 / 4 | Planner hint for OS cache availability |
| `work_mem` | max(RAM / max_connections / 4, 2MB) | Per-operation sort/hash memory |
| `maintenance_work_mem` | min(RAM / 16, 2GB) | VACUUM, CREATE INDEX, etc. |
| `max_connections` | 100 (<=4GB), 200 (<=16GB), 400 (>16GB) | Scaled by available memory |

## Plan-to-RAM Mapping Table

Each plan corresponds to a VM with a fixed amount of RAM. The plan name determines how `generate_pg_cmd.py` tunes PostgreSQL:

| Plan | RAM (MiB) |
|---|---|
| `micro` | 1024 |
| `small` | 2048 |
| `medium` | 4096 |
| `large` | 8192 |
| `xlarge` | 16384 |
| `2xlarge` | 32768 |
| `4xlarge` | 65536 |

## Sync with Workflow

The `accessories` workflow input is a JSON array. It must include an entry for the database accessory:

```json
[{"name": "db", "plan": "<chosen-plan>", "disk_size_gb": <size>}]
```

- **`name`**: must be `db` (matches the accessory name in `deploy.yml`)
- **`plan`**: one of the plans from the table above. Determines the VM size and therefore the RAM available for PostgreSQL tuning
- **`disk_size_gb`**: size of the data disk attached to the database VM. This is the disk mounted at `/data/` where PostgreSQL stores its data (via the `/data/pgdata` subdirectory)

Example for a medium plan with a 50 GB data disk:

```json
[{"name": "db", "plan": "medium", "disk_size_gb": 50}]
```
