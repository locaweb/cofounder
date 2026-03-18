---
name: app-deploy
description: >
  This skill should be used when the user asks to "deploy to Locaweb Cloud", "set up GitHub Actions
  deployment workflows", "create a preview environment", "add a production environment", "tear down
  an environment", "configure a custom domain", "connect to the database", "check deployment logs",
  "scale the VM", "recover from snapshots", "disaster recovery", "what is the app URL",
  "what is the deployed URL", "where is my app", or asks about architecture decisions
  (monolith vs microservices, vertical vs horizontal scaling), platform constraints (Postgres only,
  single container, port 80), managing secrets and environment variables, Dockerfile requirements,
  database migrations, or performing operations and troubleshooting on live infrastructure (SSH access,
  container logs, health checks).
---

# App Deploy

## Overview

To deploy web apps, create for each environment:

- A deploy workflow: `.github/workflows/deploy-{env}.yml`
- A teardown workflow: `.github/workflows/teardown-{env}.yml`
- An environment-specific Kamal config: `config/deploy.{env}.yml`
- An environment-specific secrets file: `.kamal/secrets.{env}`

And common to all environments:

- A Kamal deploy config: `config/deploy.yml`
- A common secrets file: `.kamal/secrets-common`
- A single `Dockerfile` at repo root

See [references/workflows.md](references/workflows.md) for deploy and [references/teardown.md](references/teardown.md) for teardown workflow syntax. See the [examples/](examples/) folder for `.kamal/` (secrets) and `config/` (Kamal config) example files. The `.kamal/` and `config/` folders live at the repo root so the Kamal deploy job can access them.

### How the deploy workflow works

```
                     Caller workflow (.github/workflows/deploy-{env}.yml)
                          |                              |
                  provisioning job                      deploy job
                          |                              |
                          v                              v
+----------------------------------+   +----------------------------------+
|  External workflow               |   |  Kamal deployment                |
|(gmautner/locaweb-cloud-provision)|   |  (runs in caller's deploy job)   |
|                                  |   |                                  |
|  Provisions infrastructure:      |   |  kamal setup / kamal deploy      |
|    VMs, networks, disks, IPs,    |   |  Builds and pushes Docker image  |
|    firewalls, snapshots, DNS     |   |  Deploys to provisioned VMs      |
|                                  |   |  Reboots scaled accessories      |
|  Outputs: infra_env, IPs,        |   |                                  |
|    infrastructure_changed,       |   |                                  |
|    scaled_accessories            |   |                                  |
+----------------------------------+   +----------------------------------+
```

### What the provision job owns

- Infrastructure provisioning (VMs, networks, disks, firewall, DNS, snapshots)
- Outputs: `infra_env`, `infrastructure_changed`, `scaled_accessories`, `web_ip`, `worker_ips`, `accessory_ips`

## Platform Constraints (Read First)

These constraints apply to **every** application deployed to this platform. Communicate these upfront when starting any deployment work:

- **Single Dockerfile at repo root**, web app **must listen on port 80**, otherwise adjust the `app_port` in the `proxy` block of `/config/deploy.yml`
- **Health check at `GET /up`** returning HTTP 200 when healthy
- **`forward_headers: false` is non-negotiable** -- VMs are directly exposed to the internet with no upstream proxy. The agent must never set this to `true`.
- **Single web VM**: No horizontal web scaling. Scale vertically with larger `web_plan` (see [references/scaling.md -- VM Plans](references/scaling.md#vm-plans) for available sizes). Prefer runtimes and frameworks that scale well vertically.
- **Workers use the same Docker image** with a different command (`servers.workers.cmd` in `deploy.yml`).
- **`volumes` for app roles, `directories` for accessories** -- For main app roles (web, workers), use Kamal's `volumes` keyword for persistent data mounts. For accessories, use `directories` (which support `mode` and `owner` options). Both are auto-created on the host by Kamal and map directly to host paths — making data visible, portable, and backed up. Never use named Docker volumes (`myapp_data:/path`). For `directories` syntax (string and hash formats), mode/owner options, and the distinction between `volumes` and `directories`, see [references/kamal.md — Accessories](references/kamal.md#accessories).
- **Host path must be `/data/{subdir}`** -- both the web VM and each accessory VM have a persistent disk mounted at `/data/`. Always mount subdirectories of `/data/`, never `/data/` root directly (see [references/env-vars.md -- Disk Storage Path](references/env-vars.md#disk-storage-path) for web usage, [references/postgres-recipe.md -- Volume Mount](references/postgres-recipe.md#volume-mount-datapgdata-not-data) for the database example). Two reasons: (1) `/data/` is an attached disk with scheduled snapshot policies that ensure disaster recovery — data outside `/data/` is not backed up; (2) the ext4 filesystem creates `lost+found` at the mount root, which breaks Docker images that expect a clean directory on first boot (PostgreSQL `initdb`, Redis `appendonly.aof`, etc.).
- **No Docker build in the caller workflow**: The caller's deploy job builds, pushes, and deploys the Docker image via Kamal. The caller workflow must **not** include any separate Docker build or push steps (no `docker/build-push-action`, no `docker build`, no `docker push`, no login to ghcr.io). Kamal handles the entire build-push-deploy lifecycle using the Dockerfile at the repo root.
- **Always enable TLS**: Set `proxy.ssl: true` in every environment config — both nip.io and custom domains get automatic Let's Encrypt certificates via HTTP-01 challenge. Let's Encrypt has never failed to increase rate limits for nip.io when asked, so nip.io subdomains are safe to use with TLS.
- **Accessories are flexible** -- Each accessory gets its own VM with a data disk. Additional accessories (Redis, WAHA, Meilisearch, etc.) can be added via the Kamal layer when appropriate. For PostgreSQL, see the [`supabase/postgres` recipe](references/postgres-recipe.md) — a Postgres image enriched with several extensions, as recommended by the **tech-stack** skill. Accessories that serve HTTP/HTTPS traffic through kamal-proxy need ports 80 and 443 opened at the firewall — pass `"ports": "80,443"` in the accessory's JSON entry (port 22/SSH is always open). See [references/kamal.md — Accessories](references/kamal.md#accessories) for proxy configuration details.
- **Accessory reboot on every deploy** -- `kamal deploy` does not update accessories, but the deploy workflow runs `kamal accessory reboot all` after `kamal setup` on every deploy. This ensures accessory config changes (image tag, env vars, volumes, ports, cmd) are always applied. Accessories have downtime during reboot (no rolling deploy). See [references/kamal.md — Accessories](references/kamal.md#accessories) for details.
- **Naming rules** -- `env_name` and accessory `name` values must use only lowercase letters, digits, and underscores (`[a-z0-9_]`). No hyphens, uppercase, or special characters.

If the application's current design conflicts with any of these, resolve the conflict **before** proceeding with deployment setup.

## Scripts

### `generate_pg_cmd.py`

Outputs the complete PostgreSQL `cmd` string tuned for a VM plan, if using the [`supabase/postgres` recipe](references/postgres-recipe.md). Use this for the `accessories.db.cmd` field in `config/deploy.<environment>.yml`.

```bash
mise x -- python3 scripts/generate_pg_cmd.py --plan medium
# Output: postgres -D /etc/postgresql -c shared_buffers=1GB -c effective_cache_size=3GB -c work_mem=10MB -c maintenance_work_mem=256MB -c max_connections=100
```

Valid plans: `micro`, `small`, `medium`, `large`, `xlarge`, `2xlarge`, `4xlarge`.

## Setup Procedure

Follow these steps in order. Each step is idempotent -- safe to re-run across agent sessions.

### Step 1: Prepare the application

- Meet all [Dockerfile Requirements](#dockerfile-requirements) -- single Dockerfile at root, port 80, health check at `/up`
- If using workers: ensure the same Docker image supports a separate command for the worker process

### Step 2: Ensure a GitHub repository is configured

- Check if a git remote is configured: `git remote -v`
- If `origin` is already set, skip this step
- If no remote is configured, set one up using the **repo-setup** skill before continuing

### Step 3: Generate SSH key

Check if an SSH key already exists for this repo:

```bash
test -f ~/.ssh/<repo-name> && echo "Key exists" || echo "Key missing"
```

If the key already exists, reuse it -- do not overwrite.

If the key does not exist, generate a new Ed25519 SSH key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<repo-name> -N "" -C "<repo-name>-deploy"
chmod 600 ~/.ssh/<repo-name>
```

This key will be:
- Stored as the `SSH_PRIVATE_KEY` GitHub secret (the private key)
- Used locally to SSH into preview environment VMs for debugging
- The public key is derived automatically by the deploy workflow at runtime

### Step 4: Collect CloudStack credentials

```bash
gh secret list
```

**If both `CLOUDSTACK_API_KEY` and `CLOUDSTACK_SECRET_KEY` appear → skip to Step 5.**

Otherwise:

**A. Check for a Locaweb Cloud account**

Ask the user: **"Você já tem uma conta na Locaweb Cloud?"**

- **No** → tell them to visit [locaweb.com.br/locaweb-cloud](https://www.locaweb.com.br/locaweb-cloud/) and click **"Contratar"** to sign up. Wait for them to confirm they have an account, then continue with **B**.
- **Yes** → continue with **B**.

**B. Find the API keys**

Guide the user through these steps:

1. Open [painel-cloud.locaweb.com.br](https://painel-cloud.locaweb.com.br/)
2. Navigate to: **Contas** → *(sua conta)* → **Visualizar usuarios** → *(seu usuario)*
3. **Wait up to 60 seconds** -- the keys load asynchronously and may not appear immediately. They show up under **"Criado"** (creation date) on the user page.

If the keys **do not** appear after waiting:

4. Click the **"Gerar novas chaves"** icon in the **upper right corner** of the user page.
5. Wait for the keys to appear.

**Wait for the user to confirm they have both keys in hand, then continue with C.**

**C. Create the GitHub secrets**

Give them the GitHub secrets URL:

```bash
echo "$(gh repo view --json url -q .url)/settings/secrets/actions"
```

Ask them to open that URL and click **"New repository secret"** for each:

| Name | What to paste |
|------|--------------|
| `CLOUDSTACK_API_KEY` | **Copiar Chave da API** |
| `CLOUDSTACK_SECRET_KEY` | **Copiar Chave secreta** |

**Wait for the user to confirm both secrets are saved, then continue to Step 5.**

### Step 5: Set up app secrets (database, API keys, etc.)

For the full secrets and environment variables reference, see [references/env-vars.md](references/env-vars.md).

**Discover all app env vars:** Read the project's `.env` file to get the full list of environment variables the application uses. Cross-reference with the application's config loading code (e.g., `backend/internal/config/config.go`) to confirm which variables are expected. For each variable, decide:

- **Skip** — local-development-only (`DEV_MODE` must never be set in production) or already set directly in the Kamal config's `env.clear` or Dockerfile (example: `PORT`)
- **Derived** — composed from other secrets in `.kamal/secrets` (`DATABASE_URL` from `POSTGRES_PASSWORD`)
- **Clear** — non-sensitive, goes in `env.clear` in the Kamal config (no GitHub Secret needed)
- **Secret** — sensitive, needs a GitHub Secret + entry in `.kamal/secrets.<env>` + entry in `env.secret` + entry in the workflow `env:` block

Keep this classified list — it drives Steps 6 and 7.

Check which secrets already exist via `gh secret list`.

If the app uses the [`supabase/postgres` recipe](references/postgres-recipe.md), set up database secrets:

- Generate a random password for each environment:

  ```bash
  # Preview password
  mise x -- python -c "import secrets; print(secrets.token_urlsafe(32))"

  # Production password (different from preview)
  mise x -- python -c "import secrets; print(secrets.token_urlsafe(32))"
  ```
- Set `POSTGRES_PASSWORD` as a GitHub Secret using `gh secret set --body` with the generated password (the agent does this directly -- never ask the user to set generated passwords)
- `DATABASE_URL` is **not** a separate GitHub Secret -- it is derived from `POSTGRES_PASSWORD` in the `.kamal/secrets` file (see [examples/](examples/) for the pattern)
- The default preview environment uses unsuffixed names: `POSTGRES_PASSWORD`
- Additional environments use suffixed names matching the environment name: e.g., `POSTGRES_PASSWORD_PRODUCTION`

For any other app secrets identified in the discovery step above, give the user the GitHub secrets URL and ask them to click **"New repository secret"** for each one individually.

- **Never** accept secret values through the chat

### Step 6: Create GitHub secrets

Use `gh secret list` to check which secrets already exist -- only create missing ones.

#### Secrets the agent sets directly

```bash
# SSH private key for preview (skip if already set)
gh secret set SSH_PRIVATE_KEY < ~/.ssh/<repo-name>

# Postgres password for preview (skip if already set)
gh secret set POSTGRES_PASSWORD --body "<generated password from Step 5>"
```

For additional environments, use suffixed names:

```bash
# SSH private key for production
gh secret set SSH_PRIVATE_KEY_PRODUCTION < ~/.ssh/<repo-name>-production

# Postgres password for production
gh secret set POSTGRES_PASSWORD_PRODUCTION --body "<generated password from Step 5>"
```

Note: `DATABASE_URL` does not need a GitHub Secret -- it is derived from `POSTGRES_PASSWORD` in the `.kamal/secrets` file.

#### App-specific secrets (user must set via GitHub UI)

For secrets only the user knows (app API keys, SMTP credentials, etc.), give them the GitHub secrets URL:

```bash
echo "$(gh repo view --json url -q .url)/settings/secrets/actions"
```

For each secret, ask them to click **"New repository secret"** and tell them the exact **Name** to enter and where to find the **value**. **Wait for the user to confirm all app-specific secrets are added before continuing.**

### Step 7: Create Kamal configuration and secrets files

The agent must write these files directly. See the [examples/](examples/) folder for complete working examples.

#### 7a: Common config (`config/deploy.yml`)

Kamal config applicable to all environments. See [references/env-vars.md](references/env-vars.md) for environment variable and secrets configuration details. Contains:

- **Proxy settings** -- `app_port`, `forward_headers`, healthcheck
- **SSH and registry** -- user, keys, ghcr.io registry with ERB templates
- **Builder** -- arch and cache settings
- **Common environment variables** -- `env.clear` for non-sensitive config (do NOT put `env.secret` here; secrets must go in each destination file)
- **Common volumes** -- host mounts applicable to all environments
- **Workers** (if any) -- `servers.workers.cmd` and `servers.workers.proxy: false`
- **Deployment timings** -- `readiness_delay`, `deploy_timeout`, `drain_timeout` (sensible defaults: 15, 180, 30)

For Postgres accessories, follow the [`supabase/postgres` recipe](references/postgres-recipe.md). Generate the `cmd` string using `generate_pg_cmd.py --plan <chosen_plan>`.

#### 7b: Environment-specific config (`config/deploy.{env}.yml`)

Environment-specific Kamal config. See [references/env-vars.md -- Clear Variables](references/env-vars.md#clear-variables-deployyml) for environment-specific variable placement. Contains:

- **Server hosts** -- web and worker IPs via ERB templates (e.g., `<%= ENV['INFRA_WEB_IP'] %>`)
- **Environment-specific variables** -- `env.clear` (e.g., `APP_ENV: preview`) and `env.secret` for secrets specific to this environment
- **Proxy host and TLS** -- nip.io for preview (`<%= ENV['INFRA_WEB_IP'] %>.nip.io`), custom domain for production. Always `ssl: true`.
- **Accessories** -- image, host (ERB), port, cmd, env, directories

**IMPORTANT — `INFRA_*_IP` is for Kamal and external URLs only:** The `INFRA_*_IP` env vars contain **public** IPs. Use them only in Kamal's `host:` fields (SSH deployment), `servers.web.hosts` / `servers.workers.hosts`, and `proxy.host` (external-facing URLs). **Never** use `INFRA_*_IP` in `env.clear` or `env.secret` for inter-component communication (database hosts, cache endpoints, message brokers, etc.). Instead, use the CloudStack internal DNS hostname — the accessory name (e.g., `db`, `redis`). See [references/kamal.md — Accessories](references/kamal.md#accessories) for details.

#### 7c: Common secrets (`.kamal/secrets-common`)

Secrets shared across all environments. Each line maps a Kamal secret name (left) to a shell environment variable name (right):

```
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
MY_SECRET=$MY_SECRET
```

**`KAMAL_REGISTRY_PASSWORD` is NOT a GitHub Secret and the user does NOT need to create a PAT.** It is set automatically in the deploy workflow step as `KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}` — the built-in GitHub Actions token that has `packages: write` permission (declared in the workflow's `permissions` block). See the workflow examples in [references/workflows.md](references/workflows.md).

#### 7d: Environment-specific secrets (`.kamal/secrets.{env}`)

Secrets for a specific environment. Each line maps a Kamal secret name to either a shell env var or a derived value. See the [examples/](examples/) folder for the full pattern:

```
# .kamal/secrets.preview (unsuffixed env var names)
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
```

```
# .kamal/secrets.production (suffixed env var names)
POSTGRES_PASSWORD=$POSTGRES_PASSWORD_PRODUCTION
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD_PRODUCTION}@db:5432/postgres
```

Note that `DATABASE_URL` is derived directly from `POSTGRES_PASSWORD` -- it does not need a separate GitHub Secret.

#### How secrets flow from GitHub to your app

```
GitHub Secrets  -->  Workflow env: block  -->  Shell environment  -->  .kamal/secrets*  -->  Kamal  -->  Container
```

1. **GitHub Secrets** store the actual values (e.g., `POSTGRES_PASSWORD`, `API_KEY_PRODUCTION`)
2. The deploy workflow's **`env:` block** maps each GitHub Secret to an environment variable on the runner
3. When Kamal runs with `-d <destination>`, it reads **`.kamal/secrets-common`** and **`.kamal/secrets.<destination>`** to resolve secret values from the shell environment
4. Secrets listed in **`env.secret`** in `config/deploy.yml` (common) and `config/deploy.<env>.yml` (env-specific) are injected into the container

The left side of each secrets file line is the **Kamal secret name** (referenced in `env.secret`). The right side is the **shell environment variable name** (which matches the GitHub Secret name). For non-preview environments, the GitHub Secret is suffixed (e.g., `POSTGRES_PASSWORD_PRODUCTION`), so the right side maps to the suffixed name while the left side stays unsuffixed.

**Accessory-to-config sync:** The `accessories` JSON array in the caller workflow's infra job must match the accessories declared in `config/deploy.<env>.yml`. Each accessory needs a corresponding entry in the JSON array with a matching `name`, plus the desired `plan` and `disk_size_gb`. Accessories that use kamal-proxy (i.e., have a `proxy` block in the Kamal config) also need `"ports": "80,443"` to open the firewall for HTTP/HTTPS traffic.

**Forward sync (development → deployment):** When generating the `accessories` JSON for the workflow and the accessory blocks in the Kamal destination config, use `docs/INFRASTRUCTURE.md` as the source of truth for which accessories exist, their images, and their environment variables.

**Reverse sync (deployment → development):** When adding, removing, or changing accessories in the Kamal config or workflow (e.g., the user asks to add Redis during deployment setup, or to remove an accessory that is no longer needed), update `docs/INFRASTRUCTURE.md` to match before the task is complete. The infrastructure manifest and Kamal accessory config must always describe the same set of services.

**WARNING: `disk_size_gb` is MANDATORY for every accessory.** Even if the accessory does not need persistent storage, you must include `disk_size_gb` with a value in the range 10–4000 GB. Example: `{"name":"nginx","plan":"small","disk_size_gb":10,"ports":"80,443"}`.

**Naming: accessory `name` must use only lowercase letters, digits, and underscores (`[a-z0-9_]`).** No hyphens, uppercase, or special characters.

Example sync:

```yaml
# In config/deploy.preview.yml:
accessories:
  db:
    image: supabase/postgres:17.6.1.097
    # ... backend service, no proxy

  n8n:
    image: n8nio/n8n:latest
    host: <%= ENV['INFRA_N8N_IP'] %>
    proxy:
      host: n8n.<%= ENV['INFRA_N8N_IP'] %>.nip.io
      ssl: true
      app_port: 5678
    # ... web-facing, uses kamal-proxy

# In caller workflow (infra job):
with:
  accessories: '[{"name":"db","plan":"medium","disk_size_gb":20},{"name":"n8n","plan":"small","disk_size_gb":10,"ports":"80,443"}]'
```

### Step 8: Create deploy and teardown workflows

Write the deploy and teardown workflows for each environment. See [references/workflows.md](references/workflows.md) for the full two-job deploy pattern, input reference, and examples. See [references/teardown.md](references/teardown.md) for the teardown workflow pattern.

Start with a **preview environment**:

1. Create `.github/workflows/deploy-preview.yml` following the two-job pattern from workflows.md -- an `infra` job that calls the reusable provision workflow, and a `deploy` job that runs Kamal
2. Create `.github/workflows/teardown-preview.yml` following the teardown pattern from teardown.md

The deploy workflow's `env:` block must include every GitHub Secret that the `.kamal/secrets` files reference. For preview (unsuffixed):

```yaml
env:
  POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
```

Secrets derived in the `.kamal/secrets` file (like `DATABASE_URL` composed from `POSTGRES_PASSWORD`) do not need their own GitHub Secret or workflow env entry.

### Step 9: Add additional environments (when ready)

The preview workflow (triggered on push) gives immediate feedback on every change to the main branch, matching a typical developer flow. Other environments can be added depending on the team's processes.

A common choice is a **"production" environment** triggered on version tags (`v*`), where a tag signals that the pointed commit is ready for production. Feel free to create other environments with different triggers and workflow inputs to match your needs.

For each additional environment:

- Generate a separate SSH key: `~/.ssh/<repo-name>-<env_name>` (same procedure as Step 3)
- Store it as a suffixed GitHub secret matching the environment name: e.g., `SSH_PRIVATE_KEY_PRODUCTION`
- If using a database, create a separate secret with the same suffix: e.g., `POSTGRES_PASSWORD_PRODUCTION`
- If the app has custom secrets scoped to the environment, suffix them the same way: e.g., `API_KEY_PRODUCTION`, `SMTP_PASSWORD_PRODUCTION`
- Secrets common to all environments (e.g., `CLOUDSTACK_API_KEY`, `CLOUDSTACK_SECRET_KEY`) don't need to be recreated -- just pass them in every caller workflow
- Write a new environment-specific Kamal config: `config/deploy.<env>.yml` (same structure as the preview config, with the appropriate hosts, proxy host, and accessories)
- Write a `.kamal/secrets.<env>` file mapping Kamal secret names to suffixed env var names (e.g., `POSTGRES_PASSWORD=$POSTGRES_PASSWORD_PRODUCTION`)
- Create a deploy workflow: `.github/workflows/deploy-<env>.yml` (same two-job pattern, with the environment's trigger, secrets, and inputs)
- Create a teardown workflow: `.github/workflows/teardown-<env>.yml`
- For production with a custom domain, see [DNS Configuration](#dns-configuration-for-custom-domains)

## Deployment Feedback Loop

After setup is complete, use this loop to deploy and verify the application.

> **Prerequisite:** Before entering this loop, all changes -- including the Kamal config files, workflow files, and any application code -- must be **committed and pushed** to the remote repository. The deploy is triggered by `git push`. If the code has not been committed and pushed yet, do that first:
>
> ```bash
> git add -A && git commit -m "Add deployment config and workflows" && git push
> ```
>
> The tech-stack skill normally handles this, but if there was a handoff gap, ensure it happens now before proceeding.

```
+-----------------------------------------------------+
|                                                      |
|   Push triggers GitHub Actions workflow              |
|        |                                             |
|        v                                             |
|   Monitor workflow run (gh run watch)                |
|        |                                             |
|        v                                             |
|   Workflow succeeds? --No--> Read logs, fix,         |
|        |                     commit/push,            |
|       Yes                    repeat                  |
|        |                                             |
|        v                                             |
|   Health check: curl /up -> HTTP 200?                |
|        |                                             |
|       Yes --> Done (deployment verified)             |
|        |                                             |
|       No                                             |
|        |                                             |
|        v                                             |
|   SSH debug (logs, container state)                  |
|        |                                             |
|        v                                             |
|   Return to tech-stack Local Development             |
|   Feedback Loop to diagnose and fix                  |
|                                                      |
+-----------------------------------------------------+
```

### Workflow monitoring

After push, **before starting to monitor**, give the user a prominent clickable link to the workflow run:

```bash
gh run list --limit=1 --json databaseId,url -q '.[0].url'
```

Present it prominently:

> **Your deploy is running! Follow it live here:**
>
> **\<URL from the command above\>**

Then monitor the run:

```bash
gh run watch
```

If the workflow fails, read the error:

```bash
gh run view <run-id> --log-failed
```

Common failure causes:
- **Missing secrets**: `gh secret list` to verify all required secrets exist
- **Dockerfile issues**: build failures, wrong port, missing health check
- **Permission errors**: ensure `permissions: contents: read, packages: write` in the caller workflow
- **Input errors**: invalid zone, plan name, or type mismatches

Fix the issue, commit, and push. The preview workflow (triggered on push) will start a new run automatically. Continue the cycle until the workflow succeeds.

### Health check verification

- Run `curl -s -o /dev/null -w "%{http_code}" https://<web_ip>.nip.io/up` (get `web_ip` from the workflow run summary)
- For custom domains: `curl -s -o /dev/null -w "%{http_code}" https://<domain>/up`
- If the health check returns HTTP 200, the deployment is verified and complete
- If the health check fails or the app doesn't respond: SSH into the VMs to check logs (see [references/operations.md -- Container Debugging](references/operations.md#container-debugging) for commands), then return to the **tech-stack** skill's Local Development Feedback Loop to diagnose and fix the issue

## Modifying Accessories in an Existing Deployment

When adding, removing, or changing an accessory after the initial deployment:

1. **Update `docs/INFRASTRUCTURE.md`** — add or remove the row.
2. **Update the Kamal destination config** (`config/deploy.<env>.yml`) — add or remove the accessory block. For new accessories, include image, host (ERB), port, cmd, env, and directories. For web-facing accessories, add the `proxy` block with a health check path the image actually exposes (not `/up`).
3. **Update the workflow** (`.github/workflows/deploy-<env>.yml`) — add or remove the entry in the `accessories` JSON. Remember:
   - `disk_size_gb` is mandatory for every accessory
   - Web-facing accessories need `"ports": "80,443"`
   - The `name` must match the Kamal config
4. **Update env vars** — if the new accessory introduces an env var:
   - Clear (no credential): add to `env.clear` in the Kamal config
   - Secret (has credential): add to `env.secret`, create the GitHub Secret, add to `.kamal/secrets.<env>`, and add to the workflow's `env:` block
5. **Commit, push, re-deploy.** The workflow provisions the new accessory VM (or deprovisions the removed one) and Kamal applies the config change.

When removing an accessory, also check whether any application code still references its env var and remove the dependency.

## Operations (Post-Deployment)

Quick reference for interacting with deployed infrastructure. See [references/operations.md](references/operations.md) for full details.

| Task | Command pattern |
|---|---|
| Get deployment IPs | `rm -rf $HOME/tmp/provision-output && gh run download <run-id> --name provision-output --dir $HOME/tmp/provision-output` |
| SSH into a VM | Resolve key first: `REPO_NAME=$(gh repo view --json name -q .name)`, then `ssh -i ~/.ssh/$REPO_NAME[-<env_name>] root@<ip>` — **always use `-i`**, never rely on the default SSH key |
| Connect to accessory (e.g. Postgres) | SSH into accessory VM -> `docker exec -it <repo-name>-db psql -U postgres` |
| View app logs | SSH into web VM -> `docker logs $(docker ps -q --filter "label=service=<repo-name>") --tail 100` |
| Check app health | `curl -s https://<web_ip>.nip.io/up` |
| Shell into app container | SSH into web VM -> `docker exec -it $(docker ps -q --filter "label=service=<repo-name>") sh` |

## Dockerfile Requirements

- Single `Dockerfile` at repository root
- Web app **must listen on port 80** (hardcoded in platform proxy config)
- Default `CMD`/entrypoint serves the web application
- If using workers, the same image must support a separate command passed via `servers.workers.cmd` in `deploy.yml`
- Health check endpoint at `GET /up` returning HTTP 200 when healthy
- If connecting to a database, read connection from the `DATABASE_URL` env var (or individual vars like `POSTGRES_HOST`, `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` if the framework requires them -- the agent sets these in `deploy.yml` under `env.clear`/`env.secret`). The app must **fail with a clear error** if it needs the database but these variables are missing -- do not silently skip database functionality.

Example minimal Dockerfile:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 80
ENV PORT=80
CMD ["gunicorn", "--bind", "0.0.0.0:80", "--workers", "2", "app:app"]
```

## Database Migrations

The platform runs a single web VM, so running migrations at container startup is the correct approach. This avoids race conditions (no concurrent instances), requires no separate migration container, and keeps migrations synchronized with the deployment lifecycle -- a new code push triggers a redeploy, which restarts the container, which runs migrations before serving traffic.

Include migrations in the container entrypoint, before the web server starts:

```dockerfile
CMD ["sh", "-c", "python manage.py migrate && exec gunicorn --bind 0.0.0.0:80 --workers 2 app:app"]
```

Ensure that:

1. **Migration commands run in the entrypoint** -- before the web server process starts. The app should not serve requests until migrations complete.
2. **All migration dependencies are bundled in the Docker image** -- SQL scripts, migration files, and any libraries used by the migration tool (e.g., `alembic`, `django`, `knex`, `ActiveRecord`) must be installed in the image. Verify that the `COPY` and `RUN pip install` (or equivalent) steps include everything the migration command needs.

## Deployment Outputs and URLs

After a deploy workflow completes, extract information from:

1. **Workflow outputs**: `web_ip`, `worker_ips` (JSON array), `accessory_ips` (JSON object keyed by accessory name), `infrastructure_changed`, `scaled_accessories`, `infra_env`
2. **GitHub Actions step summary**: visible in the workflow run UI, shows IP table and app URL
3. **`provision-output` artifact**: JSON file retained for 90 days

### Determining the app URL

- **Without domain**: `https://<web_ip>.nip.io` -- works immediately, no DNS needed, TLS via Let's Encrypt
- **With domain**: `https://<domain>` -- requires DNS A record pointing to `web_ip`, TLS via Let's Encrypt

Both nip.io and custom domains support TLS. Let's Encrypt HTTP-01 challenge provisions certificates automatically.

### Choosing the Target Environment for a Domain

When the user asks to configure a custom domain, determine which environment should receive it. **Always ask** -- do not default to the only existing environment without confirming.

Explain the options in the user's language, using these concepts:

- **Local dev environment**: Runs on the user's own computer. Not visible to anyone else. Good for iterating on new features and bug fixes quickly.
- **Preview environment**: Runs on the cloud. Visible to anyone with the URL. Typically triggered on every push to the main branch. Good for quick iteration and sharing with testers. If a domain is tied here, every push goes live immediately.
- **Production environment**: A separate cloud environment, typically triggered on version tags (`v*`). Changes are staged in preview first and only promoted to production when a tag is created. Tie the domain here for a controlled release process.

**Decision point:** If the user has no production environment, ask them:

1. **Tie the domain to Preview** -- for immediate release. Every push goes live. Simple, fast, good for getting started.
2. **Create a Production environment first** -- for a controlled release process. Preview becomes a staging area; production gets the domain.

Mention that this can be changed later (e.g., moving the domain from preview to production, or adding a new domain to production), so there is no wrong choice to start with.

If a local development environment is not available (the user cannot run the app locally), recommend option 2 more strongly: without local dev, preview is the only place to catch issues before they go live, so it's valuable to keep it as a staging area separate from the public-facing production environment.

Once the user decides, proceed with [DNS Configuration](#dns-configuration-for-custom-domains) for the chosen environment. If a production environment is needed but doesn't exist yet, create it first following [Step 9](#step-9-add-additional-environments-when-ready).

### DNS Configuration for Custom Domains

The web VM's public IP is not known until the first deployment completes. To set up a custom domain:

1. **Deploy without a domain first** (omit `proxy.host` domain from the destination config). The app will be accessible at `https://<web_ip>.nip.io`.
2. **Note the `web_ip`** from the workflow output or step summary.
3. **Create a DNS A record** pointing the domain to that IP:
   ```
   Type: A
   Name: myapp.example.com (or @ for apex)
   Value: <web_ip from step 2>
   TTL: 300
   ```
4. **Update the destination config** (`config/deploy.<env>.yml`) to set `proxy.host` to the domain (SSL is already `true`).
5. **Commit, push, and re-deploy.** kamal-proxy will provision a Let's Encrypt certificate automatically.

Let's Encrypt HTTP-01 challenge requires the domain to resolve to the server before the certificate can be issued. The IP is stable across re-deployments to the same environment -- it only changes if the environment is torn down and recreated.

## Workers

Workers scale horizontally by changing `workers_replicas` in the caller workflow (see [references/workflows.md -- Deploy Input Reference](references/workflows.md#deploy-input-reference) for all inputs). For scaling details, see [references/scaling.md -- Scaling Workers](references/scaling.md#scaling-workers). The worker command is set in `config/deploy.yml` under `servers.workers.cmd`, not as a workflow input.

- `workers_replicas: 0` means no workers (the workflow will not provision worker VMs)
- `workers_replicas: 1` or higher provisions that many worker VMs

When workers are enabled:

1. Add `servers.workers.cmd` and `servers.workers.proxy: false` to `config/deploy.yml`:

```yaml
# config/deploy.yml
servers:
  workers:
    cmd: "celery -A tasks worker --loglevel=info"
    proxy: false
```

2. Add worker hosts to `config/deploy.{env}.yml`. The provision job exports `INFRA_WORKER_IP_0`, `INFRA_WORKER_IP_1`, etc. -- one for each `workers_replicas`:

```yaml
# config/deploy.preview.yml
servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>
  workers:
    hosts:
      - <%= ENV['INFRA_WORKER_IP_0'] %>
      - <%= ENV['INFRA_WORKER_IP_1'] %>
```

3. Set `workers_replicas` and `workers_plan` in the caller workflow's infra job:

```yaml
with:
  workers_replicas: 2
  workers_plan: "small"
```

## Scaling

Scaling happens by updating workflow inputs and/or Kamal config, then redeploying. See [references/scaling.md](references/scaling.md) for VM plans, disk sizes, and detailed instructions.

### Web (vertical only)

Change `web_plan` in the workflow and redeploy. No config file changes needed. Causes brief downtime.

### Workers

- **Vertical**: Change `workers_plan` in the workflow and redeploy. No config file changes needed. Causes brief downtime.
- **Horizontal**: Change `workers_replicas` in the workflow. **Also update the host list** in `config/deploy.<env>.yml` to match the new replica count — see [references/scaling.md -- Scaling Workers](references/scaling.md#scaling-workers) for details. Commit, push, and redeploy.

### Accessories (database, redis, etc.)

Change the `plan` in the `accessories` JSON in the workflow. **For database accessories using `supabase/postgres`**, also regenerate the `cmd` — see [references/scaling.md -- Scaling the Database](references/scaling.md#scaling-the-database) for the full procedure.

**Other accessories may also have memory-dependent configuration** (e.g., `maxmemory` for Redis, JVM heap for Elasticsearch). When scaling any accessory, review its `cmd`, `env`, or container configuration in `config/deploy.<env>.yml` and adjust parameters to match the new plan's resources.

## Teardown

See [references/teardown.md](references/teardown.md) for tearing down environments, inferring zone/env_name from existing workflows, and reading last run outputs.

## Disaster Recovery

Every deployed environment has automatic daily snapshots of all data volumes. If an environment is lost (teardown, VM failure, or data corruption), it can be recovered by running the deploy workflow with `recover: true`.

**When the user asks to "recover", "recuperar", "restore", "do DR", or "disaster recovery":** the critical action is adding `recover: true` to the infra job inputs in the deploy workflow. Without this flag, the workflow creates blank disks and the data is lost. Simply changing the zone is **not** recovery — recovery means restoring from snapshots via the `recover: true` flag.

**Recovery procedure:**

1. If the original deployment still exists in the target zone, either [tear it down](references/teardown.md) first or change the `zone` input to recover in a different zone (snapshots are replicated across zones, so recovery works in either zone)
2. Add `recover: true` to the infra job's `with:` block in the deploy workflow (e.g., `.github/workflows/deploy-preview.yml`)
3. Commit, push, and monitor the workflow run
5. After recovery succeeds, verify data is intact (health check, SSH into VMs, check database rows and files)
6. **Remove `recover: true`** from the workflow file — if left in place, subsequent runs will fail because the network and volumes already exist

See [references/recovery.md](references/recovery.md) for the full procedure, pre-flight requirements, and current limitations.

## Development Without Local Environment

When the developer cannot run the language runtime or database locally, the Deployment Feedback Loop becomes the primary iteration cycle:

1. Commit and push changes
2. Monitor the workflow run until it succeeds
3. Run the health check (`curl /up`) to verify
4. If the health check fails, SSH debug, fix, and repeat from step 1

**Recommendation**: Start with the default `preview` environment triggered on push, without a domain. This gives immediate feedback on every change, with TLS via nip.io. When the app is mature, consider adding a **production** environment (triggered on version tags) for public release -- especially important when no local dev environment is available, since preview is the only place to catch issues before they reach users. See [Choosing the Target Environment for a Domain](#choosing-the-target-environment-for-a-domain) for guidance on where to attach a custom domain.

## References

- **[references/operations.md](references/operations.md)** -- Post-deployment operations: finding IPs, SSH access, database access, container debugging
- **[references/workflows.md](references/workflows.md)** -- Complete caller workflow examples (deploy + teardown) with all inputs documented
- **[references/env-vars.md](references/env-vars.md)** -- Environment variables and secrets configuration
- **[references/scaling.md](references/scaling.md)** -- VM plans, worker scaling, disk sizes
- **[references/teardown.md](references/teardown.md)** -- Teardown process, inferring parameters, reading outputs
- **[references/recovery.md](references/recovery.md)** -- Disaster recovery from snapshots: procedure, pre-flight checks, limitations
- **[references/postgres-recipe.md](references/postgres-recipe.md)** -- Recipe for the `supabase/postgres` image, a Postgres image enriched with extensions as recommended by the **tech-stack** skill
- **[references/kamal.md](references/kamal.md)** -- Kamal deployment concepts: service/worker/accessory architecture, configuration syntax, proxy, environment variables, secrets, builder, commands
