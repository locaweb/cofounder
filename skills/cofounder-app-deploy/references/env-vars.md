# Environment Variables and Secrets Configuration

## Table of Contents

- [Clear Variables (deploy.yml)](#clear-variables-deployyml)
- [Secret Variables](#secret-variables)
- [Passing Variables in Caller Workflows](#passing-variables-in-caller-workflows)
- [Inter-Component Connectivity](#inter-component-connectivity)
- [Database Connection Variables](#database-connection-variables)
- [Disk Storage Path](#disk-storage-path)

## Clear Variables (deploy.yml)

Non-sensitive configuration variables are written under `env.clear`. Variables common to all environments go in `config/deploy.yml`; environment-specific variables go in `config/deploy.<env>.yml`.

```yaml
# config/deploy.yml -- common to all environments
env:
  clear:
    LOG_LEVEL: debug
    MAX_UPLOAD_SIZE: 50MB
```

```yaml
# config/deploy.preview.yml -- environment-specific
env:
  clear:
    APP_ENV: preview
```

These become clear (non-secret) environment variables in the container.

## Secret Variables

Sensitive configuration flows directly from GitHub Secrets through the caller workflow's deploy job `env:` block, into the runner environment, where `.kamal/secrets.<dest>` reads them and passes them to the container.

### How it works

1. **Agent writes secret names** in two places:
   - `deploy.<env>.yml` under `env.secret` -- tells Kamal which env vars are secrets (list ALL secrets here, both common and env-specific)
   - `.kamal/secrets-common` and `.kamal/secrets.<destination>` -- tells Kamal to read values from the runner environment

2. **Caller workflow maps GitHub Secrets as env vars** on the deploy job:

```yaml
# In the caller workflow's deploy job
deploy:
  needs: infra
  runs-on: ubuntu-latest
  env:
    POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
    API_KEY: ${{ secrets.API_KEY }}
```

3. **Kamal reads from the environment** via `.kamal/secrets-common` and `.kamal/secrets.<destination>` and injects them into the container.

Store each secret **individually** as a GitHub Secret. Ask the user to set these via the GitHub UI (see the **app-deploy** skill, Step 6). **Never** accept secret values through the chat.

Secrets like `DATABASE_URL` that can be derived from other secrets do not need their own GitHub Secret -- they are composed in the `.kamal/secrets` file.

### deploy.yml and .kamal/secrets configuration

The agent writes secret names in `env.secret` blocks and `.kamal/secrets` files. **All secrets must be listed in each `config/deploy.<env>.yml`** — do NOT put `env.secret` in the base `config/deploy.yml`. This is because Kamal deep-merges destination files on top of the base config, and arrays are replaced (not appended). If the base config has `env.secret: [MY_SECRET]` and the destination has `env.secret: [DATABASE_URL]`, the result is only `[DATABASE_URL]` — `MY_SECRET` is silently lost.

Secret *values* still use separate `.kamal/secrets-common` (for common secrets) and `.kamal/secrets.<env>` (for env-specific secrets) files — the merge issue only affects the `env.secret` array in YAML deploy configs.

```yaml
# config/deploy.<env>.yml -- ALL secrets for this environment
env:
  secret:
    - MY_SECRET        # common secret, value from .kamal/secrets-common
    - POSTGRES_PASSWORD # env-specific, value from .kamal/secrets.<env>
    - DATABASE_URL      # env-specific, value from .kamal/secrets.<env>
```

For **preview** (default environment), the `.kamal/secrets` file uses unsuffixed env var names. Derived secrets like `DATABASE_URL` are composed inline:

```bash
# .kamal/secrets.preview
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
API_KEY=$API_KEY
```

For **non-preview** environments (e.g., production), the `.kamal/secrets` file maps the Kamal secret name (left side) to the suffixed env var name (right side):

```bash
# .kamal/secrets.production
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_PRODUCTION
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD_PRODUCTION}@db:5432/postgres
API_KEY=$API_KEY_PRODUCTION
```

## Passing Variables in Caller Workflows

See [workflows.md](workflows.md) for complete caller workflow examples showing the two-job pattern. See the **app-deploy** skill (Step 6) for how to create the secrets referenced below.

Complete example showing both clear and secret custom variables for a production environment. Note the two-job pattern: infra job handles infrastructure, deploy job handles Kamal and application secrets. Environment-scoped secrets use the `_PRODUCTION` suffix, while common secrets (`CLOUDSTACK_*`) are shared across all environments:

```yaml
jobs:
  infra:
    uses: locaweb/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "production"
      zone: "ZP01"
      accessories: '[{"name":"db","plan":"medium","disk_size_gb":50}]'
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY_PRODUCTION }}

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      POSTGRES_PASSWORD_PRODUCTION: ${{ secrets.POSTGRES_PASSWORD_PRODUCTION }}
      API_KEY_PRODUCTION: ${{ secrets.API_KEY_PRODUCTION }}
      JWT_SECRET_PRODUCTION: ${{ secrets.JWT_SECRET_PRODUCTION }}
    steps:
      # ... (checkout, load infra_env, Kamal install, deploy steps)
```

Clear variables are written directly in `deploy.yml` by the agent -- they are not passed through the workflow.

## Inter-Component Connectivity

When the app, workers, or accessories need to communicate with each other, use the **CloudStack internal DNS hostname** — the accessory name (e.g., `db`, `redis`, `waha`) — **never** use `INFRA_*_IP` env vars.

The `INFRA_*_IP` variables exported by the provision workflow contain **public** IPs. They are meant only for:
- Kamal `host:` fields (SSH deployment to VMs)
- `servers.web.hosts` / `servers.workers.hosts` (Kamal server lists)
- `proxy.host` (external-facing URLs like `<%= ENV['INFRA_WEB_IP'] %>.nip.io`)

Using public IPs for inter-component communication (database hosts, cache endpoints, message brokers, etc.) routes traffic through the external interface, which may fail due to firewall rules or the service port not being open publicly. CloudStack internal DNS resolves the accessory name to its private IP on the internal network, which is fast, reliable, and always available.

### Examples

```yaml
# CORRECT — use the accessory name as the hostname
env:
  clear:
    WORDPRESS_DB_HOST: db
    REDIS_URL: redis://redis:6379
    WAHA_API_URL: http://waha:3000

# WRONG — never use INFRA_*_IP for inter-component communication
env:
  clear:
    WORDPRESS_DB_HOST: <%= ENV['INFRA_DB_IP'] %>           # public IP, will fail
    REDIS_URL: redis://<%= ENV['INFRA_REDIS_IP'] %>:6379   # public IP, will fail
```

This rule applies to all inter-component references regardless of whether the components are on the same VM or different VMs.

## Database Connection Variables

The application uses `DATABASE_URL` to connect to the database. This is **derived from `POSTGRES_PASSWORD`** in the `.kamal/secrets` file -- it is not a separate GitHub Secret. See [postgres-recipe.md -- DATABASE_URL Derived from POSTGRES_PASSWORD](postgres-recipe.md#database_url-derived-from-postgres_password) for the full recipe.

The hostname in `DATABASE_URL` is `db`, which resolves via CloudStack internal DNS to the database VM's private IP. The format is:

```
postgres://postgres:<password>@db:5432/postgres
```

Example usage in application code:

```python
# Python example
import os
database_url = os.environ["DATABASE_URL"]
# database_url = "postgres://postgres:mypassword@db:5432/postgres"
```

```javascript
// Node.js example
const connectionString = process.env.DATABASE_URL;
```

```ruby
# Ruby/Rails example (config/database.yml)
production:
  url: <%= ENV["DATABASE_URL"] %>
```

The port is always 5432. The hostname is always `db`.

## Disk Storage Path

Both the web VM and each accessory VM have a persistent disk mounted at `/data/`. For main app roles (web, workers), use Kamal `volumes`; for accessories, use `directories`. Never use named Docker volumes. Always map to a **subdirectory** of `/data/` (never `/data/` root). `/data/` is an attached disk with scheduled snapshot policies for disaster recovery — data outside `/data/` is not backed up. Additionally, `lost+found` from the ext4 filesystem at the mount root would interfere with containers expecting a clean directory. See [postgres-recipe.md -- Volume Mount](postgres-recipe.md#volume-mount-datapgdata-not-data) for the database accessory example.

### Web VM example

To use the web disk for file storage (uploads, media, etc.):

1. Map a Kamal volume to a subdirectory of `/data/`:
   ```yaml
   volumes:
     - /data/uploads:/app/uploads
   ```
2. Set a clear env var in `deploy.yml` so the app knows the path:
   ```yaml
   env:
     clear:
       UPLOAD_PATH: /app/uploads
   ```

### Accessory VM example

Each accessory VM has its own disk at `/data/`. Map the accessory's data directory to a subdirectory:

```yaml
accessories:
  db:
    directories:
      - /data/pgdata:/var/lib/postgresql/data
  redis:
    directories:
      - /data/redis:/data
```

The subdirectory names are up to the application — there is no platform-mandated convention.
