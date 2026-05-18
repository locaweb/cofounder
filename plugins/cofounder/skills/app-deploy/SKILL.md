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
- **Secret** — sensitive, needs a GitHub Secret + entry in `.kamal/secrets.<env>` + entry in `env.secret` in `config/deploy.<env>.yml` + entry in the workflow `env:` block

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

For any other app secrets identified in the discovery step above, check whether the value already exists in the project's `.env` file:

- **OK to use same value locally and deployed** (e.g., SMTP passwords, OAuth credentials, third-party API keys, depending on the case) — the agent sets the GitHub Secret directly from `.env` (see Step 6).
- **Different value or not in `.env`** — the user must set it via the GitHub UI (see Step 6).

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

#### App-specific secrets

For secrets only the user knows (app API keys, SMTP credentials, etc.), check the project's `.env` file first. 

**Reuse from `.env`:** If the secret exists in `.env` and the same value may apply to the deployed environment, set it directly — the value never appears in chat:

```bash
# One-time setup (skip if already installed):
mise x -- pip install -q python-dotenv

# Set a secret from .env (value never appears in chat):
mise x -- python -c "from dotenv import dotenv_values; import sys; print(dotenv_values('.env')[sys.argv[1]], end='')" SECRET_NAME | gh secret set SECRET_NAME
```

**Fall back to GitHub UI:** If the secret is not in `.env`, or the deployed value should differ from the local one, give the user the GitHub secrets URL:

```bash
echo "$(gh repo view --json url -q .url)/settings/secrets/actions"
```

Ask them to click **"New repository secret"** and tell them the exact **Name** to enter and where to find the **value**. **Wait for the user to confirm all manually-added secrets are saved before continuing.**

### Step 7: Create Kamal configuration and secrets files

**Read the example files before writing.** Each sub-step below names an example file — read it with the Read tool first, then adapt it for the project. Lines marked `# do not change` must be preserved exactly. Remove sections the project doesn't need (e.g., workers, volumes). Add project-specific values where the comments indicate.

#### 7a: Common config (`config/deploy.yml`)

Read [examples/config/deploy.yml](examples/config/deploy.yml) and adapt it:

- **Add** project-specific `env.clear` variables (non-sensitive config shared by all environments)
- **Add** `volumes` entries if the app stores files on disk (keep paths under `/data/`)
- **Remove** the `servers.workers` block if the project has no workers
- **Remove** the `volumes` block if the app has no persistent storage
- **Keep** all lines marked `# do not change` exactly as-is — these are platform constraints (`forward_headers: false`, registry ERB templates, builder config, SSH user)
- **Do NOT** put `env.secret` here — arrays are replaced (not merged) by destination files, so any secrets listed here would be silently lost. Put ALL secrets in each `config/deploy.<env>.yml`

For Postgres accessories, generate the `cmd` string using `generate_pg_cmd.py --plan <chosen_plan>`. See the [`supabase/postgres` recipe](references/postgres-recipe.md).

#### 7b: Environment-specific config (`config/deploy.{env}.yml`)

Read [examples/config/deploy.preview.yml](examples/config/deploy.preview.yml) (or [examples/config/deploy.production.yml](examples/config/deploy.production.yml) for non-preview) and adapt it:

- **Set** `env.secret` to list ALL secrets for this environment (common + env-specific) — this is the only place secrets are declared
- **Set** `env.clear` for environment-specific non-sensitive config (e.g., `APP_ENV: preview`)
- **Set** accessories from `docs/INFRASTRUCTURE.md` — match image, set host via ERB (`<%= ENV['INFRA_<NAME>_IP'] %>`), configure port, cmd, env, and `directories` (always under `/data/`)
- **Set** `proxy.host` — nip.io for preview (`<%= ENV['INFRA_WEB_IP'] %>.nip.io`), custom domain for production. Always `ssl: true`
- **Remove** the `servers.workers` block if the project has no workers

**IMPORTANT — `INFRA_*_IP` is for Kamal and external URLs only:** Use `INFRA_*_IP` only in `host:` fields, `servers.*.hosts`, and `proxy.host`. **Never** in `env.clear` or `env.secret`. For inter-component communication, use the CloudStack internal DNS hostname (the accessory name, e.g., `db`, `redis`).

#### 7c: Common secrets (`.kamal/secrets-common`)

Read [examples/.kamal/secrets-common](examples/.kamal/secrets-common) and adapt it:

- **Keep** the `KAMAL_REGISTRY_PASSWORD` line — this is NOT a GitHub Secret; it comes from `secrets.GITHUB_TOKEN` in the workflow
- **Add** one line per common secret identified in Step 5 (format: `SECRET_NAME=$SECRET_NAME`)

#### 7d: Environment-specific secrets (`.kamal/secrets.{env}`)

Read [examples/.kamal/secrets.preview](examples/.kamal/secrets.preview) (or [examples/.kamal/secrets.production](examples/.kamal/secrets.production) for non-preview) and adapt it:

- **Add** one line per environment-specific secret identified in Step 5
- **Preview** uses unsuffixed env var names: `POSTGRES_PASSWORD=$POSTGRES_PASSWORD`
- **Non-preview** maps to suffixed names: `POSTGRES_PASSWORD=$POSTGRES_PASSWORD_PRODUCTION`
- **Derived** secrets (like `DATABASE_URL`) are composed inline — they don't need their own GitHub Secret

#### How secrets flow from GitHub to your app

```
GitHub Secrets  -->  Workflow env: block  -->  Shell environment  -->  .kamal/secrets*  -->  Kamal  -->  Container
```

1. **GitHub Secrets** store the actual values (e.g., `POSTGRES_PASSWORD`, `API_KEY_PRODUCTION`)
2. The deploy workflow's **`env:` block** maps each GitHub Secret to an environment variable on the runner
3. When Kamal runs with `-d <destination>`, it reads **`.kamal/secrets-common`** and **`.kamal/secrets.<destination>`** to resolve secret values from the shell environment
4. Secrets listed in **`env.secret`** in `config/deploy.yml` (common) and `config/deploy.<env>.yml` (env-specific) are injected into the container

The left side of each secrets file line is the **Kamal secret name** (referenced in `env.secret`). The right side is the **shell environment variable name** (which matches the GitHub Secret name). For non-preview environments, the GitHub Secret is suffixed (e.g., `POSTGRES_PASSWORD_PRODUCTION`), so the right side maps to the suffixed name while the left side stays unsuffixed.

**Accessory sync:** The workflow's `accessories` JSON, `config/deploy.<env>.yml`, and `docs/INFRASTRUCTURE.md` must always describe the same set of services. Each accessory needs `name`, `plan`, `disk_size_gb` in the JSON; web-facing ones also need `"ports": "80,443"`. Use `INFRASTRUCTURE.md` as source of truth in both directions — update it whenever accessories change.

**WARNING: `disk_size_gb` is MANDATORY for every accessory.** Even if the accessory does not need persistent storage, you must include `disk_size_gb` with a value in the range 10–4000 GB. Example: `{"name":"nginx","plan":"small","disk_size_gb":10,"ports":"80,443"}`.

**Naming: accessory `name` must use only lowercase letters, digits, and underscores (`[a-z0-9_]`).** No hyphens, uppercase, or special characters.

Example sync:

```yaml
# In config/deploy.preview.yml:
accessories:
  db:
    image: supabase/postgres:17.6.1.122
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

Start with a **preview environment**. Read the example workflows with the Read tool, then adapt them:

1. **Deploy workflow:** Read the **Preview Workflow Example** section in [references/workflows.md](references/workflows.md). Copy the full workflow YAML and adapt it:
   - **Set** the `accessories` JSON to match the accessories in `config/deploy.preview.yml` and `docs/INFRASTRUCTURE.md` — every accessory needs `name`, `plan`, and `disk_size_gb`; web-facing ones also need `"ports": "80,443"`
   - **Add** project secrets to the deploy job's `env:` block — one entry per GitHub Secret that `.kamal/secrets` files reference (derived secrets like `DATABASE_URL` don't need an entry)
   - **Remove** `workers_replicas` and `workers_plan` if the project has no workers
   - **Do NOT** add Docker build/push steps or `secrets: inherit` — Kamal handles the entire build-push-deploy lifecycle
   - Save as `.github/workflows/deploy-preview.yml`

2. **Teardown workflow:** Read [references/teardown.md](references/teardown.md) for the teardown pattern. Save as `.github/workflows/teardown-preview.yml`

### Step 9: Add additional environments (when ready)

The preview workflow (triggered on push) gives immediate feedback on every change to the main branch, matching a typical developer flow. Other environments can be added depending on the team's processes.

A common choice is a **"production" environment** triggered on version tags (`v*`), where a tag signals that the pointed commit is ready for production. Feel free to create other environments with different triggers and workflow inputs to match your needs.

For each additional environment:

- Generate a separate SSH key: `~/.ssh/<repo-name>-<env_name>` (same procedure as Step 3)
- Store it as a suffixed GitHub secret matching the environment name: e.g., `SSH_PRIVATE_KEY_PRODUCTION`
- If using a database, create a separate secret with the same suffix: e.g., `POSTGRES_PASSWORD_PRODUCTION`
- If the app has custom secrets scoped to the environment **with different values per env**, suffix them the same way: e.g., `API_KEY_PRODUCTION`.
- Secrets common to all environments (e.g., `CLOUDSTACK_API_KEY`, `CLOUDSTACK_SECRET_KEY`) don't need to be recreated -- just pass them in every caller workflow
- Write a new environment-specific Kamal config: `config/deploy.<env>.yml` (same structure as the preview config, with the appropriate hosts, proxy host, and accessories)
- Write a `.kamal/secrets.<env>` file mapping Kamal secret names to suffixed env var names (e.g., `POSTGRES_PASSWORD=$POSTGRES_PASSWORD_PRODUCTION`)
- Create a deploy workflow: `.github/workflows/deploy-<env>.yml` (same two-job pattern, with the environment's trigger, secrets, and inputs)
- Create a teardown workflow: `.github/workflows/teardown-<env>.yml`
- For production with a custom domain, see [DNS Configuration](#dns-configuration-for-custom-domains)

## Deployment Feedback Loop

All changes (Kamal config, workflows, application code) **must** be committed and pushed before entering this loop — deploy is triggered by `git push`.

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

Give the user a clickable link first: `gh run list --limit=1 --json databaseId,url -q '.[0].url'`.

Present it prominently:

> **Your deploy is running! Follow it live here:**
>
> **\<URL from the command above\>**

Then monitor with `gh run watch`.

On failure: `gh run view <run-id> --log-failed`. Common causes: missing secrets, Dockerfile issues (port/health check), permission errors, invalid inputs. Fix, commit, push — preview auto-triggers on push.

### Health check verification

`curl -s -o /dev/null -w "%{http_code}" https://<web_ip>.nip.io/up` (or `https://<domain>/up`). HTTP 200 = done. If it fails, SSH debug (see [references/operations.md](references/operations.md)), then return to the tech-stack Local Development Feedback Loop to fix.

## Modifying Accessories in an Existing Deployment

1. Update `docs/INFRASTRUCTURE.md`
2. Update `config/deploy.<env>.yml` — add/remove accessory block (image, host ERB, port, cmd, env, directories; web-facing: add `proxy` block)
3. Update workflow `accessories` JSON — `disk_size_gb` mandatory, web-facing need `"ports": "80,443"`, `name` must match Kamal config
4. Update env vars if needed — clear → `env.clear`; secret → `env.secret` + GitHub Secret + `.kamal/secrets.<env>` + workflow `env:` block
5. Commit, push, re-deploy. When removing, also remove code references to the accessory's env var.

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
- Web app **must listen on port 80**
- Health check at `GET /up` → HTTP 200
- If using workers, same image must support a separate command via `servers.workers.cmd` in `config/deploy.<env>.yml`
- Database connection via `DATABASE_URL` env var — **fail hard** if missing

For Go+React apps, see the **tech-stack** skill's Dockerfile section. For other stacks, ensure port 80 and the health check endpoint are configured.

## Database Migrations

Single web VM → run migrations at container startup (no race conditions). Include migrations in the entrypoint before the web server starts. All migration dependencies must be bundled in the Docker image.

## Deployment Outputs and URLs

After deploy, information is available from: workflow outputs (`web_ip`, `worker_ips`, `accessory_ips`, `infrastructure_changed`, `scaled_accessories`, `infra_env`), the Actions step summary, and the `provision-output` artifact (90-day retention).

**App URL:** Without domain: `https://<web_ip>.nip.io`. With domain: `https://<domain>` (requires DNS A record). Both get TLS via Let's Encrypt HTTP-01.

### Choosing the Target Environment for a Domain

When the user asks to configure a custom domain, **always ask** which environment should receive it — never default silently. Options:

1. **Preview** — every push goes live immediately. Simple, fast.
2. **Production** — preview becomes staging; only tagged releases go live. Safer, with a more stable release cycle.

Mention that this can be changed later. Then proceed with [DNS Configuration](#dns-configuration-for-custom-domains). If production doesn't exist yet, create it via [Step 9](#step-9-add-additional-environments-when-ready).

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

#### Apex domains and www

For apex domains (e.g., `example.com`), **proactively include** `www`. Use the `hosts:` array in the proxy config and instruct the user to create **two** DNS A records:

```
Type: A    Name: @      Value: <web_ip>    TTL: 300
Type: A    Name: www    Value: <web_ip>    TTL: 300
```

The destination config uses `proxy.hosts` (array) instead of `proxy.host` (string):

```yaml
proxy:
  hosts:
    - example.com
    - www.example.com
  ssl: true
```

kamal-proxy will provision separate Let's Encrypt certificates for each hostname. Both DNS records must resolve to the server before deployment.
**Canonical redirect:** `BASE_URL` is always the bare domain. The app **must** redirect `www` → bare (HTTP 301) at the application level — kamal-proxy does not do host-to-host redirects. This avoids inconsistent OAuth callbacks, cookies, and links.

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

Without a local runtime, use the Deployment Feedback Loop as the primary cycle: commit/push → monitor workflow → health check → SSH debug if needed → repeat. Start with preview (push-triggered, no domain, TLS via nip.io). Add production later — especially important without local dev, since preview is the only pre-production check.

## References

- **[references/operations.md](references/operations.md)** -- Post-deployment operations: finding IPs, SSH access, database access, container debugging
- **[references/workflows.md](references/workflows.md)** -- Complete caller workflow examples (deploy + teardown) with all inputs documented
- **[references/env-vars.md](references/env-vars.md)** -- Environment variables and secrets configuration
- **[references/scaling.md](references/scaling.md)** -- VM plans, worker scaling, disk sizes
- **[references/teardown.md](references/teardown.md)** -- Teardown process, inferring parameters, reading outputs
- **[references/recovery.md](references/recovery.md)** -- Disaster recovery from snapshots: procedure, pre-flight checks, limitations
- **[references/postgres-recipe.md](references/postgres-recipe.md)** -- Recipe for the `supabase/postgres` image, a Postgres image enriched with extensions as recommended by the **tech-stack** skill
- **[references/kamal.md](references/kamal.md)** -- Kamal deployment concepts: service/worker/accessory architecture, configuration syntax, proxy, environment variables, secrets, builder, commands
