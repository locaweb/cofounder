# Environment Variables and Secrets Configuration

## Table of Contents

- [Clear Variables (deploy.yml)](#clear-variables-deployyml)
- [Secret Variables](#secret-variables)
- [Passing Variables in Caller Workflows](#passing-variables-in-caller-workflows)
- [Database Connection Variables](#database-connection-variables)
- [Web Disk Storage Path](#web-disk-storage-path)

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
   - `deploy.yml` under `env.secret` -- tells Kamal which env vars are secrets
   - `.kamal/secrets.<destination>` -- tells Kamal to read them from the runner environment

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

Store each secret **individually** as a GitHub Secret. Ask the user to set these via the GitHub UI (see [setup-and-deploy.md -- Secrets the user must set via GitHub UI](setup-and-deploy.md#secrets-the-user-must-set-via-github-ui)). **Never** accept secret values through the chat.

Secrets like `DATABASE_URL` that can be derived from other secrets do not need their own GitHub Secret -- they are composed in the `.kamal/secrets` file.

### deploy.yml and .kamal/secrets configuration

The agent writes secret names in `env.secret` blocks and `.kamal/secrets` files. Common secrets go in `config/deploy.yml` and `.kamal/secrets-common`; environment-specific secrets go in `config/deploy.<env>.yml` and `.kamal/secrets.<env>`:

```yaml
# config/deploy.yml -- secrets common to all environments
env:
  secret:
    - MY_SECRET
```

```yaml
# config/deploy.preview.yml -- environment-specific secrets
env:
  secret:
    - POSTGRES_PASSWORD
    - DATABASE_URL
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

See [workflows.md](workflows.md) for complete caller workflow examples showing the two-job pattern. See [setup-and-deploy.md -- Creating GitHub Secrets](setup-and-deploy.md#creating-github-secrets) for how to create the secrets referenced below.

Complete example showing both clear and secret custom variables for a production environment. Note the two-job pattern: infra job handles infrastructure, deploy job handles Kamal and application secrets. Environment-scoped secrets use the `_PRODUCTION` suffix, while common secrets (`CLOUDSTACK_*`) are shared across all environments:

```yaml
jobs:
  infra:
    uses: gmautner/locaweb-cloud-provision/.github/workflows/provision.yml@v1
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

## Web Disk Storage Path

The web VM has a persistent disk mounted at `/data/`. To use it for file storage (uploads, media, etc.):

1. Map a Kamal volume to a **subdirectory** of `/data/` (never `/data/` root — `lost+found` from ext4 would interfere):
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

The subdirectory name and env var name are up to the application — there is no platform-mandated convention.
