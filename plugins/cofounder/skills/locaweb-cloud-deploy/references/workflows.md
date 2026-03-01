# Caller Workflow Reference

## Table of Contents

- [Preview Workflow (Default)](#preview-workflow-default)
- [Additional Environments](#additional-environments)
- [Deploy Input Reference](#deploy-input-reference)
- [Complete Example (All Inputs)](#complete-example-all-inputs)
- [Workflow Permissions](#workflow-permissions)
- [Passing Outputs to Downstream Jobs](#passing-outputs-to-downstream-jobs)

## Preview Workflow (Default)

The default preview environment is triggered on push, immediately reflecting changes to the main branch -- matching a typical developer workflow. No domain needed, uses nip.io for immediate access with TLS. Since `"preview"` is the default `env_name`, secrets use unsuffixed names.

```yaml
# .github/workflows/deploy-preview.yml
name: Deploy Preview
on:
  push:
    branches: [main]
    paths-ignore: [".claude/**"]

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    uses: gmautner/locaweb-cloud-deploy/.github/workflows/deploy.yml@v0
    with:
      env_name: "preview"
      zone: "ZP01"
      accessories: '{"db": {"plan": "medium", "disk_size_gb": 20}}'
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
      SECRET_ENV_VARS: |-
        POSTGRES_PASSWORD=${{ secrets.POSTGRES_PASSWORD }}
        DATABASE_URL=${{ secrets.DATABASE_URL }}
```

After this runs successfully, the app is accessible at `https://<web_ip>.nip.io`. The `web_ip` is visible in the workflow run summary.

## Additional Environments

Other environments can be created depending on your processes, changing the triggers and workflow inputs as needed. Each `env_name` creates fully isolated infrastructure.

### Secret naming convention

Since `"preview"` is the default environment, its secrets use **unsuffixed** names:

- `SSH_PRIVATE_KEY`, `POSTGRES_PASSWORD`, `DATABASE_URL`
- Custom secrets: `API_KEY`, `SMTP_PASSWORD`

For additional environments, suffix secret names that are **scoped to that environment** with the environment name (uppercased):

- `SSH_PRIVATE_KEY_PRODUCTION`, `POSTGRES_PASSWORD_PRODUCTION`, `DATABASE_URL_PRODUCTION`
- Custom secrets: `API_KEY_PRODUCTION`, `SMTP_PASSWORD_PRODUCTION`

Secrets **common to all environments** (e.g., `CLOUDSTACK_API_KEY`, `CLOUDSTACK_SECRET_KEY`) don't need suffixes -- just pass them in every caller workflow.

The caller workflow maps the suffixed secrets to the reusable workflow's standard secret names (see example below).

### Production workflow example

A recommended additional environment is **"production"**, triggered on version tags (`v*`). A tag signals that the pointed commit is ready for production.

```yaml
# .github/workflows/deploy-production.yml
name: Deploy Production
on:
  push:
    tags: ["v*"]  # Triggered by version tags (e.g., git tag v1.0.0 && git push --tags)

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    uses: gmautner/locaweb-cloud-deploy/.github/workflows/deploy.yml@v0
    with:
      env_name: "production"
      zone: "ZP01"
      web_plan: "medium"
      web_disk_size_gb: 50
      accessories: '{"db": {"plan": "medium", "disk_size_gb": 50}}'
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY_PRODUCTION }}
      SECRET_ENV_VARS: |-
        POSTGRES_PASSWORD=${{ secrets.POSTGRES_PASSWORD_PRODUCTION }}
        DATABASE_URL=${{ secrets.DATABASE_URL_PRODUCTION }}
```

To deploy to production: `git tag v1.0.0 && git push --tags`. The workflow checks out the tagged commit, so the Dockerfile and source code match the tag exactly.

## Deploy Input Reference

All inputs, their types, defaults, and when to use them:

| Input | Type | Default | When to set |
|-------|------|---------|-------------|
| `env_name` | string | `"preview"` | Name of the environment. Each env_name creates fully isolated infrastructure. Defaults to `"preview"` if omitted. |
| `zone` | string | `"ZP01"` | CloudStack zone. Usually leave as default. Use `ZP02` for geographic redundancy. |
| `web_plan` | string | `"small"` | Choose based on runtime footprint and environment. See [scaling.md](scaling.md) for plan specs. |
| `web_disk_size_gb` | number | `20` | Persistent disk attached to the web VM at `/data`. Increase if the app stores files (uploads, media). Can only grow, never shrink. |
| `accessories` | string (JSON) | `"{}"` | JSON object defining accessories (db, redis, etc.). Each key is an accessory name with `plan` and `disk_size_gb` fields. Example: `'{"db": {"plan": "medium", "disk_size_gb": 20}}'` |
| `workers_replicas` | number | `0` | Number of worker VMs. `0` means no workers. Set to 1 or more to enable background processing. |
| `workers_plan` | string | `"small"` | VM size for workers. Choose based on worker workload intensity. See [scaling.md](scaling.md). |
| `automatic_reboot` | boolean | `true` | Enable automatic reboot after unattended security upgrades. Usually leave as default. |
| `automatic_reboot_time_utc` | string | `"05:00"` | When automatic reboots happen. Usually leave as default. |
| `recover` | boolean | `false` | Reserved for future disaster recovery workflows. Do not use. |

### Inputs to leave at defaults

For most deployments, omit these (let defaults apply):
- `automatic_reboot` / `automatic_reboot_time_utc` -- security auto-updates are good defaults
- `recover` -- reserved for future use
- `web_disk_size_gb` -- 20 GB is sufficient for most apps unless heavy file storage

## Complete Example (All Inputs)

Full-stack example with web, database, redis, and workers. Every input is shown with required/optional and default value annotations.

```yaml
# .github/workflows/deploy-preview.yml
name: Deploy Preview
on:
  push:
    branches: [main]
    paths-ignore: [".claude/**"]

permissions:
  contents: read
  packages: write

jobs:
  deploy:
    uses: gmautner/locaweb-cloud-deploy/.github/workflows/deploy.yml@v0
    with:
      env_name: "preview"                    # Optional, default: "preview"
      zone: "ZP01"                           # Optional, default: "ZP01" (options: ZP01, ZP02)
      web_plan: "small"                      # Optional, default: "small"
      web_disk_size_gb: 20                   # Optional, default: 20 (grow only, never shrink)
      accessories: |-                        # Optional, default: "{}" (JSON object)
        {"db": {"plan": "medium", "disk_size_gb": 20}, "redis": {"plan": "small", "disk_size_gb": 10}}
      workers_replicas: 2                    # Optional, default: 0 (0 = no workers)
      workers_plan: "small"                  # Optional, default: "small"
      automatic_reboot: true                 # Optional, default: true
      automatic_reboot_time_utc: "05:00"     # Optional, default: "05:00"
      recover: false                         # Optional, default: false (reserved for future DR)
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}       # Required
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }} # Required
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}             # Required
      SECRET_ENV_VARS: |-                                        # Required when accessories include db
        POSTGRES_PASSWORD=${{ secrets.POSTGRES_PASSWORD }}
        DATABASE_URL=${{ secrets.DATABASE_URL }}
        API_KEY=${{ secrets.API_KEY }}
        SMTP_PASSWORD=${{ secrets.SMTP_PASSWORD }}
```

## Workflow Permissions

The deploy caller workflow **must** include:

```yaml
permissions:
  contents: read
  packages: write
```

`packages: write` is required because the reusable deploy workflow pushes the container image to ghcr.io internally via Kamal. The teardown workflow does not need `packages: write`.

## No Docker Build Steps in Caller Workflows

Do **not** add any of these to the caller workflow:

- `docker/build-push-action` or `docker/login-action` actions
- `docker build`, `docker push`, or `docker login` commands
- Any step that builds or pushes a container image

The reusable deploy workflow handles the entire Docker lifecycle internally: it checks out the application code, generates a Kamal configuration pointing to ghcr.io, and runs `kamal setup`, which builds the image from the Dockerfile at the repo root, pushes it to ghcr.io, and deploys it to the VMs -- all in a single step. The `GITHUB_TOKEN` (provided automatically by GitHub Actions) is used as the registry credential, so no separate registry login is needed either.

## No `secrets: inherit`

The reusable workflow lives in a **public repository** (`gmautner/locaweb-cloud-deploy`). GitHub does not allow `secrets: inherit` when calling a reusable workflow from a different repository. Always pass secrets explicitly in the `secrets:` block of the caller workflow.

## Passing Outputs to Downstream Jobs

The deploy workflow exposes outputs that can be consumed by subsequent jobs:

```yaml
jobs:
  deploy:
    uses: gmautner/locaweb-cloud-deploy/.github/workflows/deploy.yml@v0
    with:
      # ... inputs
    secrets:
      # ... secrets

  notify:
    needs: deploy
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "Web IP: ${{ needs.deploy.outputs.web_ip }}"
          echo "Worker IPs: ${{ needs.deploy.outputs.worker_ips }}"
          echo "Accessories: ${{ needs.deploy.outputs.accessories }}"
```

Available outputs:
- `web_ip` -- Public IP of the web VM
- `worker_ips` -- JSON array of worker VM public IPs (e.g., `["1.2.3.4","5.6.7.8"]`)
- `accessories` -- JSON object with accessory IPs. Each key is the accessory name (e.g., `db`, `redis`) with `ip` (public) and `internal_ip` (private) fields. Example: `{"db": {"ip": "200.234.x.x", "internal_ip": "10.1.1.x"}, "redis": {"ip": "200.234.y.y", "internal_ip": "10.1.1.y"}}`
