# Kamal

Kamal deploys Docker containers to bare metal or VMs using zero-downtime rolling deploys with an integrated reverse proxy (kamal-proxy). It uses a base `deploy.yml` config file with per-environment destination overrides, and connects via SSH — no Kubernetes, no orchestrator.

## Architecture: Service, Workers, and Accessories

A Kamal deployment has three types of components:

### Service (the app)

The **service** builds and runs the Dockerfile in the default **web** servers role. This is the primary application — it receives traffic through kamal-proxy.

- The Dockerfile at the repo root defines the service image
- The default `CMD` in the Dockerfile runs the web server
- kamal-proxy routes incoming HTTP/HTTPS traffic to the service container
- **For automatic TLS certificate issue and renewal via Let's Encrypt, run only one web server** — Let's Encrypt HTTP-01 challenge requires a single point to answer the challenge; multiple web servers behind the proxy would race on certificate provisioning

### Workers

**Workers** use the same Dockerfile as the service but run an alternate `CMD`. They are background job processors that don't receive web traffic.

Worker command and behavior go in the base `config/deploy.yml`:

```yaml
# config/deploy.yml
servers:
  workers:
    cmd: "celery -A tasks worker --loglevel=info"
```

Worker hosts go in the destination config `config/deploy.{env}.yml`:

```yaml
# config/deploy.preview.yml
servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>
  workers:
    hosts:
      - <%= ENV['INFRA_WORKER_IP_0'] %>
```

- Workers share the same Docker image — only the command differs
- The proxy is only enabled on the primary role (web) by default — all other roles including workers have it disabled, so there is no need to set `proxy: false` explicitly
- Workers can have their own `options`, `env`, `labels`, and `logging` overrides
- Multiple worker roles are possible for different job types (define each in the base config with its `cmd`, then assign hosts per destination)

### Accessories

**Accessories** are standalone Docker containers for public images — databases (MySQL, PostgreSQL), messaging (Kafka, WAHA gateway), caches (Redis), automation tools (n8n), search engines (Meilisearch), and similar services.

Accessories are defined in the destination config `config/deploy.{env}.yml`:

```yaml
# config/deploy.preview.yml
accessories:
  db:
    image: supabase/postgres:17.6.1.093
    host: <%= ENV['INFRA_DB_IP'] %>
    port: "5432:5432"
    cmd: "postgres -D /etc/postgresql -c shared_buffers=1GB -c max_connections=100"
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - /data/pgdata:/var/lib/postgresql/data
```

Accessories can also run behind kamal-proxy to receive routed HTTP and HTTPS traffic. This is useful for web-facing services like dashboards, admin panels, or APIs. With `ssl: true`, Let's Encrypt certificate issuance and auto-renewal works for accessories as well. The accessory's port must be opened in the infrastructure's public IP firewall — kamal-proxy only routes traffic that reaches the host.

```yaml
# config/deploy.preview.yml
accessories:
  nginx:
    image: nginx:alpine
    host: <%= ENV['INFRA_NGINX_IP'] %>
    directories:
      - /data/nginx/html:/usr/share/nginx/html
    proxy:
      host: docs.example.com
      ssl: true
      # host: docs.<%= ENV['INFRA_NGINX_IP'] %>.nip.io
      # ssl: false
      app_port: 80
```

Key characteristics:
- Accessories use public Docker images — they are **not** built from the repo's Dockerfile
- Each accessory is deployed to specific hosts independently from the app
- Accessories are **not** updated on `kamal deploy` — any configuration change (image tag bump, env var change, volume/port/cmd adjustment, etc.) requires `kamal accessory reboot <name>` to take effect
- Accessories have downtime on reboot (no rolling deploy) — always warn the user before rebooting
- The proxy is disabled by default on accessories. Enable with `proxy: {...}` to route traffic through kamal-proxy — the accessory's port must be open at the infrastructure firewall level for traffic to reach the host
- Use `directories` for persistent data mounts — Kamal automatically creates them on the host before starting the container, unlike `volumes` which require the directory to already exist. Directories also support ownership customization:

```yaml
# String format — host:container
directories:
  - /data/pgdata:/var/lib/postgresql/data

# Hash format — with mode and owner
directories:
  - local: /data/redis
    remote: /data
    mode: "0750"
    owner: "999:999"
```

- Use `files` for config file mounts, optionally with permissions: `files: [{local: config/my.cnf, remote: /etc/mysql/my.cnf, mode: "0600", owner: "mysql:mysql"}]`
- Use `volumes` for raw Docker volume mounts when neither `directories` nor `files` applies — volumes are passed directly to `docker run` and the host path must already exist

## Configuration

### deploy.yml (base config)

The central configuration file at `config/deploy.yml`. Contains settings common to all environments — service identity, proxy behavior, registry, builder, SSH, common env vars, worker definitions, and deployment timings. Server hosts, accessories, and environment-specific settings go in destination files instead.

```yaml
service: myapp
image: myapp

proxy:
  app_port: 80
  forward_headers: false
  healthcheck:
    path: /up
    interval: 3
    timeout: 5

ssh:
  user: root

registry:
  server: ghcr.io
  username: myorg
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  arch: amd64
  cache:
    type: gha
    options: mode=max

env:
  clear:
    MY_VAR: hello
  secret:
    - MY_SECRET              # from .kamal/secrets-common

servers:                      # only needed if using workers
  workers:
    cmd: "bin/worker"

readiness_delay: 15
deploy_timeout: 180
drain_timeout: 30
```

### Destinations (environment-specific config)

Per-environment override files at `config/deploy.{env}.yml` (e.g. `deploy.preview.yml`, `deploy.production.yml`). Kamal deep-merges the destination file on top of the base `deploy.yml`. Deploy with: `kamal deploy -d preview`.

Destination files contain: server hosts (web + workers), environment-specific env vars, proxy host/ssl, and accessories.

```yaml
# config/deploy.preview.yml
servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>
  workers:
    hosts:
      - <%= ENV['INFRA_WORKER_IP_0'] %>

env:
  clear:
    APP_ENV: preview
  secret:
    - DATABASE_URL           # from .kamal/secrets.preview

proxy:
  host: <%= ENV['INFRA_WEB_IP'] %>.nip.io
  ssl: false

accessories:
  db:
    image: supabase/postgres:17.6.1.093
    host: <%= ENV['INFRA_DB_IP'] %>
    port: "5432:5432"
    cmd: "postgres -D /etc/postgresql -c shared_buffers=1GB"
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - /data/pgdata:/var/lib/postgresql/data
```

Deep merge rules:
- Scalar values are replaced
- Arrays are replaced (not appended)
- Hashes are recursively merged

Enforce explicit destination with `require_destination: true` in the base config.

### ERB Templating

Every YAML config file is processed through Ruby's ERB before YAML parsing: `ERB.new(File.read(file)).result`. This enables environment variable injection:

```yaml
servers:
  web:
    hosts:
      - <%= ENV['WEB_IP'] %>
```

ERB is evaluated at deploy time on the machine running `kamal deploy`.

## Proxy (kamal-proxy)

Built-in reverse proxy for zero-downtime deploys, automatic TLS, health checking, and request buffering.

### Core settings

```yaml
proxy:
  host: app.example.com       # Route only matching requests (optional)
  app_port: 3000               # Port the app listens on (default: 80)
  ssl: true                    # Let's Encrypt automatic TLS
  forward_headers: false       # Recommended when VMs are directly exposed to the internet with no upstream proxy
  response_timeout: 30         # Seconds (default: 30)
  ssl_redirect: true           # Redirect HTTP to HTTPS (default: true)
```

Multiple hosts:

```yaml
proxy:
  hosts:
    - foo.example.com
    - bar.example.com
```

### Custom TLS certificates

```yaml
proxy:
  ssl:
    certificate_pem: CERTIFICATE_PEM    # Secret names
    private_key_pem: PRIVATE_KEY_PEM
```

### Health checks

kamal-proxy checks the app before routing traffic:

```yaml
proxy:
  healthcheck:
    path: /up            # Default: /up
    interval: 1          # Seconds between checks (default: 1)
    timeout: 5           # Seconds per check (default: 5)
```

### Request/response buffering

```yaml
proxy:
  buffering:
    requests: true
    responses: true
    max_request_body: 40_000_000
    max_response_body: 0
    memory: 2_000_000
```

### Path-based routing

```yaml
proxy:
  path_prefix: "/api,/oauth_callback"
  strip_path_prefix: false
```

### Proxy on roles

- **Primary role (web)**: proxy enabled by default. Disable explicitly with `proxy: false` if needed
- **Other roles (workers, accessories, etc.)**: proxy disabled by default — no need to set `proxy: false`. Enable with `proxy: true` or custom proxy config

### Proxy runtime settings

```yaml
proxy:
  run:
    http_port: 80          # Default: 80
    https_port: 443        # Default: 443
    metrics_port: 9090
    log_max_size: "10m"
```

## Environment Variables and Secrets

### Clear variables

Non-sensitive values, placed in `env.clear` in either the base or destination config:

```yaml
# config/deploy.yml — common to all environments
env:
  clear:
    BLOB_STORAGE_PATH: /data/blobs
```

```yaml
# config/deploy.preview.yml — environment-specific
env:
  clear:
    APP_ENV: preview
```

### Secrets

Secret names are listed in `env.secret`; values are resolved from `.kamal/secrets-common` and `.kamal/secrets.<destination>` at deploy time:

```yaml
# config/deploy.yml — secrets common to all environments
env:
  secret:
    - MY_SECRET              # resolved from .kamal/secrets-common
```

```yaml
# config/deploy.preview.yml — environment-specific secrets
env:
  secret:
    - DATABASE_URL           # resolved from .kamal/secrets.preview
```

`.kamal/secrets-common` and `.kamal/secrets.<destination>` are dotenv files evaluated in the shell context:

```
# .kamal/secrets-common
KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD
MY_SECRET=$MY_SECRET
```

```
# .kamal/secrets.preview
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
DATABASE_URL=postgres://postgres:${POSTGRES_PASSWORD}@db:5432/postgres
```

### Aliased secrets

Map a different secret name to the env var:

```yaml
env:
  secret:
    - DB_PASSWORD:MAIN_DB_PASSWORD
```

### Tag-based env variables

Per-host or per-tag environment overrides:

```yaml
servers:
  - 1.1.1.1
  - 1.1.1.2: monitoring

env:
  clear:
    ROLE: standard
  tags:
    monitoring:
      ROLE: monitor
```

### Secret adapters

Kamal can fetch secrets from password managers:

```shell
SECRETS=$(kamal secrets fetch --adapter 1password --account myaccount --from MyVault/MyItem DB_PASSWORD)
DB_PASSWORD=$(kamal secrets extract DB_PASSWORD $SECRETS)
```

Supported adapters: 1Password, LastPass, Bitwarden, AWS Secrets Manager, GCP Secret Manager, Doppler.

## Docker Registry

### Docker Hub (default)

```yaml
registry:
  username: dockerhub_user
  password:
    - KAMAL_REGISTRY_PASSWORD
```

### GitHub Container Registry

```yaml
registry:
  server: ghcr.io
  username: github_user
  password:
    - KAMAL_REGISTRY_PASSWORD
```

### AWS ECR

```yaml
registry:
  server: <account-id>.dkr.ecr.<region>.amazonaws.com
  username: AWS
  password: <%= %x(aws ecr get-login-password) %>
```

### Local registry

Kamal starts it automatically:

```yaml
registry:
  server: localhost:5555
```

## Builder

```yaml
builder:
  arch: amd64                      # Required: amd64, arm64, or both
  dockerfile: Dockerfile.production  # Default: Dockerfile
  context: .                       # Default: Git HEAD
  target: production               # For multi-stage builds
  args:
    RUBY_VERSION: 3.2.0
  secrets:
    - GITHUB_TOKEN
  cache:
    type: registry                 # or "gha" for GitHub Actions cache
    image: myapp-build-cache
    options: mode=max
```

Remote builder for cross-architecture:

```yaml
builder:
  arch:
    - amd64
    - arm64
  remote: ssh://docker@docker-builder
  local: true    # Use local when arch matches (default)
```

### Cloud Native Buildpacks (alternative to Dockerfile)

```yaml
builder:
  pack:
    builder: heroku/builder:24
    buildpacks:
      - heroku/ruby
```

## Servers and Roles

### Simple server list (implicitly web role)

```yaml
servers:
  - 1.1.1.1
  - 1.1.1.2
```

### Role definitions in the base config

The base `deploy.yml` defines role behavior (cmd, proxy, options). Hosts go in the destination config:

```yaml
# config/deploy.yml — role behavior
servers:
  workers:
    cmd: bin/jobs
    options:
      memory: 2g
      cpus: 4
    env:
      clear:
        WORKER_THREADS: "5"
```

```yaml
# config/deploy.preview.yml — hosts per environment
servers:
  web:
    hosts:
      - <%= ENV['INFRA_WEB_IP'] %>
  workers:
    hosts:
      - <%= ENV['INFRA_WORKER_IP_0'] %>
```

### Server tags

Tags allow per-host environment variable overrides:

```yaml
servers:
  web:
    - 1.1.1.1
    - 1.1.1.2: experiments
    - 1.1.1.3: [experiments, monitoring]
```

## Boot and Rollout

### Staged rollout

```yaml
boot:
  limit: 25%          # Deploy to 25% of hosts at a time (or integer)
  wait: 10            # Seconds between groups
  parallel_roles: true # Boot roles in parallel on same host
```

### Container options

```yaml
options:
  restart: unless-stopped
  memory: 2g
  cpus: 4
```

### Health checks for non-proxy roles

Roles without the proxy use Docker health checks (defined in the base config):

```yaml
# config/deploy.yml
servers:
  workers:
    cmd: bin/worker
    options:
      health-cmd: bin/worker-healthcheck
      health-start-period: 5s
      health-interval: 5s
      health-retries: 5
```

### Deployment timings

```yaml
deploy_timeout: 30     # Seconds to wait for container readiness (default: 30)
drain_timeout: 30      # Seconds to wait for request draining (default: 30)
readiness_delay: 7     # Wait time for containers without healthchecks (default: 7)
```

## SSH

```yaml
ssh:
  user: root                # Default: root
  keys: [.kamal/ssh_key]    # Private key file(s)
```

Additional options:

```yaml
ssh:
  user: root
  port: "22"                # Default: 22
  proxy: root@proxy-host    # SSH jump host
  keys:
    - .kamal/ssh_key
  key_data:
    - SSH_PRIVATE_KEY        # Secret name containing the key
```

### SSHKit tuning (for many servers)

```yaml
sshkit:
  max_concurrent_starts: 30   # Default: 30
  pool_idle_timeout: 900       # Default: 900
```

## Hooks

Lifecycle scripts in `.kamal/hooks/` (no file extension). A non-zero exit code aborts the command.

Available hooks:
- `docker-setup` — after Docker is installed
- `pre-connect` — before connecting to servers
- `pre-build` — before building the image
- `pre-deploy` — before deploying
- `post-deploy` — after successful deployment
- `pre-app-boot` — before booting app container
- `post-app-boot` — after app container boots
- `pre-proxy-reboot` — before rebooting proxy
- `post-proxy-reboot` — after proxy reboots

Environment variables available in hooks:
- `KAMAL_PERFORMER` — local user
- `KAMAL_SERVICE_VERSION` — e.g. `app@150b24f`
- `KAMAL_VERSION` — full version hash
- `KAMAL_HOSTS` — comma-separated target hosts
- `KAMAL_COMMAND` / `KAMAL_SUBCOMMAND` — command being run
- `KAMAL_DESTINATION` — destination (e.g. `staging`)

## Directories and Asset Bridging

### Directories

```yaml
# config/deploy.yml — directories on the web VM
directories:
  - /data/blobs:/data/blobs
```

### Asset bridging

For apps with content-hashed assets (CSS/JS), Kamal mounts both old and new asset directories during deployment to avoid 404s:

```yaml
asset_path: /public
```

## Logging

```yaml
logging:
  driver: json-file
  options:
    max-size: 100m
```

Can be set at root level or per-role.

## Retain Containers

```yaml
retain_containers: 5    # Keep last 5 old containers for rollback (default: 5)
```

## YAML Anchors

Reuse configuration blocks with YAML anchors (prefix with `x-`):

```yaml
# config/deploy.yml
x-worker-healthcheck: &worker-healthcheck
  health-cmd: bin/worker-healthcheck
  health-start-period: 5s
  health-retries: 5
  health-interval: 5s

servers:
  queue:
    cmd: bin/queue
    options:
      <<: *worker-healthcheck
  scheduler:
    cmd: bin/scheduler
    options:
      <<: *worker-healthcheck
```

## Commands

### Deployment

| Command | Description |
|---------|-------------|
| `kamal deploy` | Full deploy: build, push, boot, route traffic, prune |
| `kamal deploy -d staging` | Deploy to a specific destination |
| `kamal setup` | First-time setup: install Docker, boot accessories, deploy |
| `kamal redeploy` | Fast redeploy: skip setup/proxy/pruning |
| `kamal rollback <VERSION>` | Revert to a previous version |

Deploy options: `--skip-push`, `--primary`, `--hosts=HOST1,HOST2`, `--roles=ROLE1`, `--skip-hooks`.

### App management

| Command | Description |
|---------|-------------|
| `kamal app containers` | List running containers (use `-q` for rollback versions) |
| `kamal app logs` | Stream application logs |
| `kamal app exec <CMD>` | Run a command inside the app container |
| `kamal app details` | Detailed container info |
| `kamal app version` | Show running version |

### Accessories

| Command | Description |
|---------|-------------|
| `kamal accessory boot <NAME>` | Start an accessory |
| `kamal accessory boot all` | Start all accessories |
| `kamal accessory reboot <NAME>` | Restart an accessory — **required** after any config change (image tag, env, volumes, ports, cmd). Causes downtime. |
| `kamal accessory reboot all` | Restart all accessories |
| `kamal accessory logs <NAME>` | View accessory logs |
| `kamal accessory exec <NAME> <CMD>` | Run command in accessory container |
| `kamal accessory remove <NAME>` | Remove an accessory |

### Build

| Command | Description |
|---------|-------------|
| `kamal build push` | Build and push image |
| `kamal build pull` | Pull image on servers |
| `kamal build deliver` | Push then pull |
| `kamal build dev` | Build locally (tagged as 'dirty') |

### Other

| Command | Description |
|---------|-------------|
| `kamal config` | Display resolved config (YAML) |
| `kamal lock` | Check deploy lock status |
| `kamal audit` | View audit log |
| `kamal prune` | Clean up old images/containers |
| `kamal secrets print` | Print resolved secrets (debug) |
| `kamal secrets fetch` | Fetch from password manager adapters |

## Cron Jobs

Use a dedicated role that installs the crontab from the environment:

```yaml
# config/deploy.yml — role definition
servers:
  cron:
    cmd: bash -c "(env && cat config/crontab) | crontab - && cron -f"
```

Note: cron doesn't propagate environment variables — the pattern above copies them into the crontab.

## Multiple Apps on the Same Host

Multiple apps can share a host via kamal-proxy:
- Apps with `proxy.host` configured receive only matching requests
- An app without `proxy.host` acts as a catch-all for unmatched requests
- Automatic TLS via Let's Encrypt (`ssl: true`) does not work with multiple apps on the same host — use custom certificates instead
