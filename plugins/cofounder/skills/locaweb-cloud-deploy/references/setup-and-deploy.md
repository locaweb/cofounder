# Setup and Deploy Procedures

All setup steps are idempotent -- safe to re-run across agent sessions. Check for existing resources before creating new ones.

## Table of Contents

### Setup
- [GitHub Repository (Prerequisite)](#github-repository-prerequisite)
- [SSH Key Generation](#ssh-key-generation)
- [CloudStack Credentials](#cloudstack-credentials)
- [Database Credentials](#database-credentials)
- [Creating GitHub Secrets](#creating-github-secrets)
- [Deploy Configuration Files](#deploy-configuration-files)

### Development Routine
- [Deploy Cycle](#deploy-cycle)
- [App Verification Cycle](#app-verification-cycle)
- [SSH Debugging](#ssh-debugging)

## GitHub Repository (Prerequisite)

Verify a git remote is configured:

    git remote -v

If `origin` is not set, use the **repo-setup** skill to initialize the repository before continuing.

## SSH Key Generation


### Preview environment key

Check if an SSH key already exists for this repo:

```bash
test -f ~/.ssh/<repo-name> && echo "Key exists" || echo "Key missing"
```

If the key does not exist, generate a new Ed25519 SSH key locally:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<repo-name> -N "" -C "<repo-name>-deploy"
chmod 600 ~/.ssh/<repo-name>
```

If the key already exists, reuse it -- do not overwrite.

This key will be:
- Stored as the `SSH_PRIVATE_KEY` GitHub secret (the private key)
- Used locally to SSH into preview environment VMs for debugging
- The public key is derived automatically by the deploy workflow at runtime

### Additional environment keys

Generate a separate key for each additional environment (Step 8). For example, for the "production" environment:

```bash
test -f ~/.ssh/<repo-name>-production && echo "Key exists" || echo "Key missing"
```

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<repo-name>-production -N "" -C "<repo-name>-deploy-production"
chmod 600 ~/.ssh/<repo-name>-production
```

This key will be:
- Stored as a suffixed GitHub secret matching the environment name: e.g., `SSH_PRIVATE_KEY_PRODUCTION`
- Used locally to SSH into that environment's VMs for debugging
- The caller workflow maps the suffixed secret to the workflow's standard `SSH_PRIVATE_KEY` input

## CloudStack Credentials

First check if CloudStack secrets are already set in the repo:

```bash
gh secret list
```

If `CLOUDSTACK_API_KEY` and `CLOUDSTACK_SECRET_KEY` appear in the list, skip this step.

Otherwise, ask the user to set them via the GitHub UI as described in the [Secrets the user must set via GitHub UI](#secrets-the-user-must-set-via-github-ui) section.

If the user doesn't have a Locaweb Cloud account yet, recommend they go to [locaweb.com.br/locaweb-cloud](https://www.locaweb.com.br/locaweb-cloud/) and look for the **"Contratar"** button to sign up. Once they have an account they can find their API keys in the CloudStack dashboard.

## Database Credentials

Check if the database secrets are already set in the repo:

```bash
gh secret list
```

If `POSTGRES_PASSWORD` and `DATABASE_URL` already appear, skip this step.

### Generate the Postgres password

Generate a random password for **each** environment:

```bash
# Preview password
python -c "import secrets; print(secrets.token_urlsafe(32))"

# Production password (different from preview)
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

### Create the DATABASE_URL

`DATABASE_URL` is a **static GitHub Secret** created once at setup time. The hostname is `db`, which resolves via CloudStack internal DNS to the database VM's private IP.

Format: `postgres://postgres:<password>@db:5432/postgres`

For example, if the generated password is `abc123`:
```
postgres://postgres:abc123@db:5432/postgres
```

The default preview environment uses unsuffixed names: `POSTGRES_PASSWORD`, `DATABASE_URL`.

Additional environments use suffixed names matching the environment name:
- `POSTGRES_PASSWORD_PRODUCTION`, `DATABASE_URL_PRODUCTION` for the "production" environment

The caller workflow maps the suffixed secrets to the reusable workflow's standard secret names.

## Creating GitHub Secrets

First list existing secrets to avoid overwriting them:

```bash
gh secret list
```

Only create secrets that are **not already present**.

**Security rule:** Never accept secret values through the chat -- they would be stored in conversation history. For secrets the agent knows (generated passwords, locally computed DATABASE_URL, local SSH keys), the agent can set them directly. For secrets only the user knows (CloudStack keys, app API keys), ask the user to set them via the GitHub UI (see [Secrets the user must set via GitHub UI](#secrets-the-user-must-set-via-github-ui)).

### Secrets the agent can set directly

Three infrastructure secrets per environment, plus the DATABASE_URL:

```bash
# SSH private key for preview (skip if already set)
gh secret set SSH_PRIVATE_KEY < ~/.ssh/<repo-name>

# SSH private key for additional environments, e.g. production (skip if already set)
gh secret set SSH_PRIVATE_KEY_PRODUCTION < ~/.ssh/<repo-name>-production

# Postgres password for preview (skip if already set)
gh secret set POSTGRES_PASSWORD --body "<generated password>"

# Postgres password for additional environments, e.g. production (skip if already set)
gh secret set POSTGRES_PASSWORD_PRODUCTION --body "<generated password>"

# DATABASE_URL for preview (skip if already set)
gh secret set DATABASE_URL --body "postgres://postgres:<generated password>@db:5432/postgres"

# DATABASE_URL for additional environments, e.g. production (skip if already set)
gh secret set DATABASE_URL_PRODUCTION --body "postgres://postgres:<generated password>@db:5432/postgres"
```

### Secrets the user must set via GitHub UI

Get the repository's secrets settings URL:

```bash
echo "$(gh repo view --json url -q .url)/settings/secrets/actions"
```

Give the user the URL and ask them to click **"New repository secret"** for each secret below. For each secret, tell the user:
1. The exact **Name** to enter.
2. Where to find the **Secret** value (e.g., which dashboard, settings page, or credential file to look in).

CloudStack credentials (if not already set):

| Name | Where to find the value |
|------|------------------------|
| `CLOUDSTACK_API_KEY` | [painel-cloud.locaweb.com.br](https://painel-cloud.locaweb.com.br/) -> Contas -> *(sua conta)* -> Visualizar usuarios -> *(seu usuario)* -> Copiar Chave da API |
| `CLOUDSTACK_SECRET_KEY` | Same page -> Copiar Chave secreta |

> **Note:** Warn that the keys may take some time to show up after page has loaded. If the user has never generated keys before, they should click the **"Gerar novas chaves"** icon on the top right corner of the user page.

App-specific secrets -- store each one **individually**. **Never** store `SECRET_ENV_VARS` as a single monolithic secret:

| Name | Where to find the value |
|------|------------------------|
| `API_KEY` | *(describe where the user can find this value)* |
| `SMTP_PASSWORD` | *(describe where the user can find this value)* |

Then compose them in the caller workflow's `SECRET_ENV_VARS` block:

```yaml
secrets:
  SECRET_ENV_VARS: |-
    POSTGRES_PASSWORD=${{ secrets.POSTGRES_PASSWORD }}
    DATABASE_URL=${{ secrets.DATABASE_URL }}
    API_KEY=${{ secrets.API_KEY }}
    SMTP_PASSWORD=${{ secrets.SMTP_PASSWORD }}
```

This way, updating a single secret only requires creating/updating it in the GitHub UI -- no need to remember or rewrite the others.

Verify all secrets are set:

```bash
gh secret list
```

## Deploy Configuration Files

The agent creates the following files as part of setup:

### deploy.yml

The Kamal deploy configuration. Contains service name, image, server hosts, environment variables, accessories, and other deployment settings. The agent generates this based on the application's requirements.

### .kamal/secrets.\<destination\>

One secrets file per destination. Each maps secret environment variable names so Kamal can read them from the deploy environment:

```bash
# .kamal/secrets.preview
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=$DATABASE_URL
API_KEY=$API_KEY
```

```bash
# .kamal/secrets.production
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=$DATABASE_URL
API_KEY=$API_KEY
STRIPE_LIVE_KEY=$STRIPE_LIVE_KEY
```

Since all deploys use `-d <destination>`, Kamal looks for `.kamal/secrets-common` and `.kamal/secrets.<destination>` — **not** `.kamal/secrets`. We use only per-destination files so each is a self-contained, verifiable manifest of what that environment needs.

## Deploy Cycle

After committing workflows and pushing:

### 1. Share workflow link and monitor

**Before starting to monitor**, give the user a prominent clickable link to the workflow run:

```bash
gh run list --limit=1 --json databaseId,url -q '.[0].url'
```

Present it prominently so the user can follow along in the GitHub UI:

> **Your deploy is running! Follow it live here:**
>
> **\<URL from the command above\>**

Then monitor the run:

```bash
# Watch the latest run
gh run watch

# Or list runs and watch a specific one
gh run list --limit=5
gh run watch <run-id>
```

### 2. If the workflow fails

Read the error:

```bash
# View the failed run's logs
gh run view <run-id> --log-failed
```

Common failure causes:
- **Missing secrets**: `gh secret list` to verify all required secrets exist
- **Dockerfile issues**: Build failures, wrong port, missing health check
- **Permission errors**: Ensure `permissions: contents: read, packages: write` in the caller workflow
- **Input errors**: Invalid zone, plan name, or type mismatches

Fix the issue, commit, and push. The preview workflow (triggered on push) will start a new run automatically.

### 3. Repeat until successful

Continue the cycle: read error -> fix -> commit/push -> watch run. Do not give up after one failure -- iterate.

### 4. On success, extract deployment info

```bash
# Get the web IP from the latest successful run
gh run view <run-id>

# Or download the provision-output artifact (clean first to avoid stale data)
rm -rf /tmp/provision-output
gh run download <run-id> --name provision-output --dir /tmp/provision-output
cat /tmp/provision-output/provision-output.json
```

The app URL is `https://<web_ip>.nip.io` (TLS works with nip.io).

## App Verification (Health Check)

After the workflow succeeds, verify the application is healthy:

### 1. Run the health check

```bash
# Health check -- must return HTTP 200
curl -s -o /dev/null -w "%{http_code}" https://<web_ip>.nip.io/up
```

If HTTP 200 is returned, the deployment is verified and the Deployment Feedback Loop is complete.

### 2. If the health check fails

SSH into the VMs to inspect logs and container state. Use the SSH key generated earlier and the public IPs from the workflow output.

See [SSH Debugging](#ssh-debugging) below for detailed commands.

After gathering diagnostic information, return to the **tech-stack** skill's Local Development Feedback Loop to diagnose and fix the issue locally before pushing again.

## SSH Debugging

Use the locally saved SSH key and the public IPs from the workflow output to connect to VMs. Use the correct key for the environment: `~/.ssh/<repo-name>` for preview, `~/.ssh/<repo-name>-<env_name>` for other environments.

```bash
# Preview
ssh -i ~/.ssh/<repo-name> root@<web_ip>
ssh -i ~/.ssh/<repo-name> root@<accessory_ip>
ssh -i ~/.ssh/<repo-name> root@<worker_ip>

# Production (or other environment -- use the corresponding key)
ssh -i ~/.ssh/<repo-name>-production root@<web_ip>
ssh -i ~/.ssh/<repo-name>-production root@<accessory_ip>
ssh -i ~/.ssh/<repo-name>-production root@<worker_ip>
```

### Useful debug commands on the VMs

```bash
# List running containers
docker ps

# View web app logs
docker logs $(docker ps -q --filter "label=service=<repo-name>") --tail 100

# Follow logs in real time
docker logs $(docker ps -q --filter "label=service=<repo-name>") -f

# Check if the app responds locally on port 80
curl -s localhost:80/up

# View kamal-proxy logs (web VM only)
docker logs kamal-proxy --tail 50

# Check Postgres container logs (accessory VM)
docker logs <repo-name>-db --tail 100

# Check disk mounts
df -h /data    # web VM or accessory VM

# Check container environment variables
docker exec $(docker ps -q --filter "label=service=<repo-name>") env
```
