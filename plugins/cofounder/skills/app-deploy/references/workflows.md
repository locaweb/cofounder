# Caller Workflow Reference

## Table of Contents

- [Caller Workflow Reference](#caller-workflow-reference)
  - [Table of Contents](#table-of-contents)
  - [Two-Job Pattern](#two-job-pattern)
  - [Preview Environment (Default)](#preview-environment-default)
    - [Preview Workflow Example](#preview-workflow-example)
  - [Additional Environments](#additional-environments)
    - [Secret naming convention](#secret-naming-convention)
  - [Production environment example](#production-environment-example)
  - [Deploy Input Reference](#deploy-input-reference)
    - [Inputs to leave at defaults](#inputs-to-leave-at-defaults)
  - [Deploy Output Reference](#deploy-output-reference)
  - [Complete Example (All Inputs)](#complete-example-all-inputs)
  - [Workflow Permissions](#workflow-permissions)
  - [No Docker Build Steps in Caller Workflows](#no-docker-build-steps-in-caller-workflows)
  - [No `secrets: inherit`](#no-secrets-inherit)
  - [Passing Outputs to Downstream Jobs](#passing-outputs-to-downstream-jobs)

## Two-Job Pattern

Caller workflows use two jobs: **provision** (infrastructure provisioning) and **deploy** (application deployment with Kamal). The provision job calls the reusable `provision.yml@v1` workflow, which provisions VMs, networks, disks, and firewall rules. The deploy job runs Kamal to build, push, and deploy the Docker image.

This separation means:
- The provision job handles only infrastructure and outputs everything the deploy job needs
- The deploy job owns the Kamal lifecycle (install, SSH key, Docker cache, `kamal setup`/`kamal deploy`)
- Application secrets flow directly from GitHub Secrets to the deploy job's `env:` block

## Preview Environment (Default)

The default preview environment is triggered on push, immediately reflecting changes to the main branch -- matching a typical developer workflow. If no domain is provided, it uses nip.io for immediate access with TLS. Since `"preview"` is the default `env_name`, secrets use unsuffixed names.

### Preview Workflow Example

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
  infra:
    uses: gmautner/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"
      zone: "ZP01"
      accessories: '[{"name":"db","plan":"medium","disk_size_gb":20}]'
      # workers_replicas: 2                  # Optional, default: 0 (0 = no workers)
      # workers_plan: "small"                # Optional, default: "small"
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
    steps:
      - name: Checkout application repository
        uses: actions/checkout@v4

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - name: Set repo identity
        run: |
          echo "REPO_NAME=${{ github.event.repository.name }}" >> "$GITHUB_ENV"
          echo "REPO_FULL=${{ github.repository }}" >> "$GITHUB_ENV"
          echo "REPO_OWNER=${{ github.repository_owner }}" >> "$GITHUB_ENV"

      - name: Configure gem path
        run: |
          echo "GEM_HOME=$HOME/.gems" >> "$GITHUB_ENV"
          echo "$HOME/.gems/bin" >> "$GITHUB_PATH"

      - name: Cache Kamal gem
        id: kamal-cache
        uses: actions/cache@v4
        with:
          path: ~/.gems
          key: kamal-${{ runner.os }}-v1

      - name: Install Kamal
        if: steps.kamal-cache.outputs.cache-hit != 'true'
        run: gem install kamal --no-document

      - name: Prepare SSH key for Kamal
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
        run: |
          mkdir -p .kamal
          install -m 600 /dev/null .kamal/ssh_key
          printf '%s\n' "$SSH_PRIVATE_KEY" > .kamal/ssh_key

      - name: Expose GitHub Actions runtime for Docker cache
        uses: actions/github-script@v7
        with:
          script: |
            const vars = [
              'ACTIONS_CACHE_URL',
              'ACTIONS_RUNTIME_TOKEN',
              'ACTIONS_RUNTIME_URL',
              'ACTIONS_RESULTS_URL',
              'ACTIONS_CACHE_SERVICE_V2',
            ];
            for (const v of vars) {
              const val = process.env[v];
              if (val) core.exportVariable(v, val);
            }

      - name: Deploy with Kamal
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if [ "${{ needs.infra.outputs.infrastructure_changed }}" = "true" ]; then
            echo "Fresh infrastructure — running kamal setup"
            kamal setup -d preview
          else
            echo "Infrastructure cached — running kamal deploy"
            kamal deploy -d preview
          fi

      - name: Reboot scaled accessories
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          python3 << 'PYEOF'
          import json, subprocess, sys
          scaled = json.loads('${{ needs.infra.outputs.scaled_accessories }}')
          for name in scaled:
              print(f"Accessory '{name}' VM was rescaled, rebooting...")
              subprocess.run(
                  ["kamal", "accessory", "reboot", name, "-d", "preview"],
                  check=True
              )
          PYEOF
```

After this runs successfully, the app is accessible at `https://<web_ip>.nip.io`. The `web_ip` is visible in the workflow run summary.

## Additional Environments

Other environments can be created depending on your processes, changing the triggers and workflow inputs as needed. Each `env_name` creates fully isolated infrastructure.

### Secret naming convention

Secrets flow directly from GitHub Secrets to the deploy job's `env:` block (see [env-vars.md -- Secret Variables](env-vars.md#secret-variables) for the full secrets configuration reference). The naming convention determines the GitHub Secret name and the environment variable name on the runner:

**Preview** (default environment) -- unsuffixed names:
- GitHub Secret: `POSTGRES_PASSWORD` → env var: `POSTGRES_PASSWORD`
- `.kamal/secrets.preview`: `POSTGRES_PASSWORD=$POSTGRES_PASSWORD`

**Non-preview** (e.g., production) -- suffixed names:
- GitHub Secret: `POSTGRES_PASSWORD_PRODUCTION` → env var: `POSTGRES_PASSWORD_PRODUCTION`
- `.kamal/secrets.production`: `POSTGRES_PASSWORD=$POSTGRES_PASSWORD_PRODUCTION`

The env var on the runner matches the GitHub Secret name exactly. The `.kamal/secrets.<dest>` file maps the Kamal secret name (left side) to the env var name (right side).

Infrastructure secrets scoped to a specific environment also use the suffix:
- `SSH_PRIVATE_KEY` (preview), `SSH_PRIVATE_KEY_PRODUCTION` (production)

Secrets **common to all environments** (e.g., `CLOUDSTACK_API_KEY`, `CLOUDSTACK_SECRET_KEY`) don't need suffixes -- just pass them in every caller workflow.

## Production environment example

A recommended additional environment is **"production"**, triggered on version tags (`v*`). A tag signals that the pointed commit is ready for production.

```yaml
# .github/workflows/deploy-production.yml
name: Deploy Production
on:
  push:
    tags: ["v*"]

permissions:
  contents: read
  packages: write

jobs:
  infra:
    uses: gmautner/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "production"
      zone: "ZP01"
      web_plan: "medium"
      web_disk_size_gb: 50
      accessories: '[{"name":"db","plan":"medium","disk_size_gb":50}]'
      # workers_replicas: 2                  # Optional, default: 0 (0 = no workers)
      # workers_plan: "small"                # Optional, default: "small"
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }}
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY_PRODUCTION }}

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      POSTGRES_PASSWORD_PRODUCTION: ${{ secrets.POSTGRES_PASSWORD_PRODUCTION }}
    steps:
      - name: Checkout application repository
        uses: actions/checkout@v4

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - name: Set repo identity
        run: |
          echo "REPO_NAME=${{ github.event.repository.name }}" >> "$GITHUB_ENV"
          echo "REPO_FULL=${{ github.repository }}" >> "$GITHUB_ENV"
          echo "REPO_OWNER=${{ github.repository_owner }}" >> "$GITHUB_ENV"

      - name: Configure gem path
        run: |
          echo "GEM_HOME=$HOME/.gems" >> "$GITHUB_ENV"
          echo "$HOME/.gems/bin" >> "$GITHUB_PATH"

      - name: Cache Kamal gem
        id: kamal-cache
        uses: actions/cache@v4
        with:
          path: ~/.gems
          key: kamal-${{ runner.os }}-v1

      - name: Install Kamal
        if: steps.kamal-cache.outputs.cache-hit != 'true'
        run: gem install kamal --no-document

      - name: Prepare SSH key for Kamal
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY_PRODUCTION }}
        run: |
          mkdir -p .kamal
          install -m 600 /dev/null .kamal/ssh_key
          printf '%s\n' "$SSH_PRIVATE_KEY" > .kamal/ssh_key

      - name: Expose GitHub Actions runtime for Docker cache
        uses: actions/github-script@v7
        with:
          script: |
            const vars = [
              'ACTIONS_CACHE_URL',
              'ACTIONS_RUNTIME_TOKEN',
              'ACTIONS_RUNTIME_URL',
              'ACTIONS_RESULTS_URL',
              'ACTIONS_CACHE_SERVICE_V2',
            ];
            for (const v of vars) {
              const val = process.env[v];
              if (val) core.exportVariable(v, val);
            }

      - name: Deploy with Kamal
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if [ "${{ needs.infra.outputs.infrastructure_changed }}" = "true" ]; then
            echo "Fresh infrastructure — running kamal setup"
            kamal setup -d production
          else
            echo "Infrastructure cached — running kamal deploy"
            kamal deploy -d production
          fi

      - name: Reboot scaled accessories
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          python3 << 'PYEOF'
          import json, subprocess, sys
          scaled = json.loads('${{ needs.infra.outputs.scaled_accessories }}')
          for name in scaled:
              print(f"Accessory '{name}' VM was rescaled, rebooting...")
              subprocess.run(
                  ["kamal", "accessory", "reboot", name, "-d", "production"],
                  check=True
              )
          PYEOF
```

To deploy to production: `git tag v1.0.0 && git push --tags`. The workflow checks out the tagged commit, so the Dockerfile and source code match the tag exactly.

## Deploy Input Reference

All inputs passed to the `infra` job (the reusable `provision.yml@v1` workflow):

| Input | Type | Default | When to set |
|-------|------|---------|-------------|
| `env_name` | string | `"preview"` | Name of the environment. Each env_name creates fully isolated infrastructure. Defaults to `"preview"` if omitted. |
| `zone` | string | `"ZP01"` | CloudStack zone. Usually leave as default. Use `ZP02` for geographic redundancy. |
| `web_plan` | string | `"small"` | Choose based on runtime footprint and environment. See [scaling.md -- VM Plans](scaling.md#vm-plans) for plan specs. |
| `web_disk_size_gb` | number | `20` | Persistent disk attached to the web VM at `/data`. Increase if the app stores files (uploads, media). Can only grow, never shrink. |
| `accessories` | string (JSON) | `"[]"` | JSON array defining accessories. Each entry has `name`, `plan`, and `disk_size_gb` fields. Example: `'[{"name":"db","plan":"medium","disk_size_gb":20}]'` |
| `workers_replicas` | number | `0` | Number of worker VMs. `0` means no workers. Set to 1 or more to enable background processing. |
| `workers_plan` | string | `"small"` | VM size for workers. Choose based on worker workload intensity. See [scaling.md -- Scaling Workers](scaling.md#scaling-workers). |
| `automatic_reboot` | boolean | `true` | Enable automatic reboot after unattended security upgrades. Usually leave as default. |
| `automatic_reboot_time_utc` | string | `"05:00"` | When automatic reboots happen. Usually leave as default. |
| `recover` | boolean | `false` | Reserved for future disaster recovery workflows. Do not use. |

### Inputs to leave at defaults

For most deployments, omit these (let defaults apply):
- `automatic_reboot` / `automatic_reboot_time_utc` -- security auto-updates are good defaults
- `recover` -- reserved for future use
- `web_disk_size_gb` -- 20 GB is sufficient for most apps unless heavy file storage

## Deploy Output Reference

The infra job exposes outputs consumed by the deploy job and optionally by downstream jobs:

| Output | Type | Description |
|--------|------|-------------|
| `web_ip` | string | Public IP of the web VM |
| `worker_ips` | string (JSON array) | Public IPs of worker VMs (e.g., `["1.2.3.4","5.6.7.8"]`) |
| `accessory_ips` | string (JSON object) | Accessory public IPs keyed by name (e.g., `{"db":"200.234.x.x","redis":"200.234.y.y"}`) |
| `infrastructure_changed` | string | `"true"` when fresh provision (cache miss), `"false"` when cached. Used to decide `kamal setup` vs `kamal deploy`. |
| `scaled_accessories` | string (JSON array) | Names of accessories whose VMs were rescaled (e.g., `["db"]`). Used to reboot affected accessories. |
| `infra_env` | string (multiline) | `KEY=VALUE` pairs for `GITHUB_ENV` (e.g., `INFRA_WEB_IP`, `INFRA_DB_IP`, `INFRA_WORKER_IP_0`). The deploy job loads these to make IPs available for Kamal ERB templates. |

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
  infra:
    uses: gmautner/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      env_name: "preview"                    # Optional, default: "preview"
      zone: "ZP01"                           # Optional, default: "ZP01" (options: ZP01, ZP02)
      web_plan: "small"                      # Optional, default: "small"
      web_disk_size_gb: 20                   # Optional, default: 20 (grow only, never shrink)
      accessories: |-                        # Optional, default: "[]" (JSON array)
        [{"name":"db","plan":"medium","disk_size_gb":20},{"name":"redis","plan":"small","disk_size_gb":10}]
      workers_replicas: 2                    # Optional, default: 0 (0 = no workers)
      workers_plan: "small"                  # Optional, default: "small"
      automatic_reboot: true                 # Optional, default: true
      automatic_reboot_time_utc: "05:00"     # Optional, default: "05:00"
      recover: false                         # Optional, default: false (reserved for future DR)
    secrets:
      CLOUDSTACK_API_KEY: ${{ secrets.CLOUDSTACK_API_KEY }}       # Required
      CLOUDSTACK_SECRET_KEY: ${{ secrets.CLOUDSTACK_SECRET_KEY }} # Required
      SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}             # Required

  deploy:
    needs: infra
    runs-on: ubuntu-latest
    env:
      POSTGRES_PASSWORD: ${{ secrets.POSTGRES_PASSWORD }}
      API_KEY: ${{ secrets.API_KEY }}
      SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}
    steps:
      - name: Checkout application repository
        uses: actions/checkout@v4

      - name: Load infrastructure environment
        run: echo "${{ needs.infra.outputs.infra_env }}" >> "$GITHUB_ENV"

      - name: Set repo identity
        run: |
          echo "REPO_NAME=${{ github.event.repository.name }}" >> "$GITHUB_ENV"
          echo "REPO_FULL=${{ github.repository }}" >> "$GITHUB_ENV"
          echo "REPO_OWNER=${{ github.repository_owner }}" >> "$GITHUB_ENV"

      - name: Configure gem path
        run: |
          echo "GEM_HOME=$HOME/.gems" >> "$GITHUB_ENV"
          echo "$HOME/.gems/bin" >> "$GITHUB_PATH"

      - name: Cache Kamal gem
        id: kamal-cache
        uses: actions/cache@v4
        with:
          path: ~/.gems
          key: kamal-${{ runner.os }}-v1

      - name: Install Kamal
        if: steps.kamal-cache.outputs.cache-hit != 'true'
        run: gem install kamal --no-document

      - name: Prepare SSH key for Kamal
        env:
          SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
        run: |
          mkdir -p .kamal
          install -m 600 /dev/null .kamal/ssh_key
          printf '%s\n' "$SSH_PRIVATE_KEY" > .kamal/ssh_key

      - name: Expose GitHub Actions runtime for Docker cache
        uses: actions/github-script@v7
        with:
          script: |
            const vars = [
              'ACTIONS_CACHE_URL',
              'ACTIONS_RUNTIME_TOKEN',
              'ACTIONS_RUNTIME_URL',
              'ACTIONS_RESULTS_URL',
              'ACTIONS_CACHE_SERVICE_V2',
            ];
            for (const v of vars) {
              const val = process.env[v];
              if (val) core.exportVariable(v, val);
            }

      - name: Deploy with Kamal
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if [ "${{ needs.infra.outputs.infrastructure_changed }}" = "true" ]; then
            echo "Fresh infrastructure — running kamal setup"
            kamal setup -d preview
          else
            echo "Infrastructure cached — running kamal deploy"
            kamal deploy -d preview
          fi

      - name: Reboot scaled accessories
        env:
          KAMAL_REGISTRY_PASSWORD: ${{ secrets.GITHUB_TOKEN }}
        run: |
          python3 << 'PYEOF'
          import json, subprocess, sys
          scaled = json.loads('${{ needs.infra.outputs.scaled_accessories }}')
          for name in scaled:
              print(f"Accessory '{name}' VM was rescaled, rebooting...")
              subprocess.run(
                  ["kamal", "accessory", "reboot", name, "-d", "preview"],
                  check=True
              )
          PYEOF
```

## Workflow Permissions

The deploy caller workflow **must** include:

```yaml
permissions:
  contents: read
  packages: write
```

`packages: write` is required because the caller's deploy job pushes the container image to ghcr.io via Kamal. The reusable infra workflow only needs `contents: read` (which it declares internally). The teardown workflow does not need `packages: write`.

## No Docker Build Steps in Caller Workflows

Do **not** add any of these to the caller workflow:

- `docker/build-push-action` or `docker/login-action` actions
- `docker build`, `docker push`, or `docker login` commands
- Any step that builds or pushes a container image

The caller's deploy job handles the entire Docker lifecycle via Kamal: it checks out the application code, and runs `kamal setup` (or `kamal deploy`), which builds the image from the Dockerfile at the repo root, pushes it to ghcr.io, and deploys it to the VMs -- all in a single step. The `GITHUB_TOKEN` (provided automatically by GitHub Actions) is used as the registry credential (`KAMAL_REGISTRY_PASSWORD`), so no separate registry login is needed.

## No `secrets: inherit`

The reusable workflow lives in a **public repository** (`gmautner/locaweb-cloud-provision`). GitHub does not allow `secrets: inherit` when calling a reusable workflow from a different repository. Always pass secrets explicitly in the `secrets:` block of the infra job. Application secrets go in the deploy job's `env:` block, not through the reusable workflow.

## Passing Outputs to Downstream Jobs

The infra job exposes outputs that can be consumed by the deploy job or additional downstream jobs:

```yaml
jobs:
  infra:
    uses: gmautner/locaweb-cloud-provision/.github/workflows/provision.yml@v1
    with:
      # ... inputs
    secrets:
      # ... secrets

  deploy:
    needs: infra
    # ... deploy steps (see examples above)

  notify:
    needs: infra
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "Web IP: ${{ needs.infra.outputs.web_ip }}"
          echo "Worker IPs: ${{ needs.infra.outputs.worker_ips }}"
          echo "Accessory IPs: ${{ needs.infra.outputs.accessory_ips }}"
          echo "Infrastructure changed: ${{ needs.infra.outputs.infrastructure_changed }}"
```

Available outputs: see [Deploy Output Reference](#deploy-output-reference).
