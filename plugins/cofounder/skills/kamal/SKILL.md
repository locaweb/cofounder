# Kamal

Kamal deploys Docker containers to bare metal or VMs using zero-downtime rolling deploys with an integrated reverse proxy (kamal-proxy). It uses a single `deploy.yml` config file and SSH — no Kubernetes, no orchestrator.

## Key Concepts

### deploy.yml

The central configuration file at `config/deploy.yml`. Defines the service name, image, servers, accessories, proxy, environment variables, volumes, builder settings, and deployment lifecycle.

### Destinations

Per-environment override files at `config/deploy.{env}.yml` (e.g. `deploy.preview.yml`, `deploy.production.yml`). Kamal deep-merges the destination file on top of the base `deploy.yml`. Deploy with: `kamal deploy -d preview`.

Deep merge means:
- Scalar values are replaced
- Arrays are replaced (not appended)
- Hashes are recursively merged

### ERB Templating

Every YAML config file is processed through Ruby's ERB before YAML parsing: `ERB.new(File.read(file)).result`. This enables environment variable injection:

```yaml
servers:
  web:
    hosts:
      - <%= ENV['WEB_IP'] %>
```

ERB is evaluated at deploy time on the machine running `kamal deploy`.

### Servers and Roles

- **web** — the primary role, receives traffic through kamal-proxy
- **workers** — background job processors (set `proxy: false`, define `cmd`)
- Custom roles possible for specialized workloads

### Accessories

Standalone Docker containers running alongside the app (databases, caches, queues). Each accessory has: `image`, `host`, `port`, `cmd` (optional), `env`, `directories`, `volumes`.

Accessories are deployed to specific hosts and managed independently from the app (`kamal accessory reboot`, `kamal accessory boot`, etc.).

### Proxy (kamal-proxy)

Built-in reverse proxy for zero-downtime deploys, automatic TLS via Let's Encrypt, health checking, and request buffering. Key config: `host`, `app_port`, `ssl`, `healthcheck`, `forward_headers`.

### Environment Variables

Two categories:
- **clear** — non-sensitive values, stored in `deploy.yml` under `env.clear`
- **secret** — sensitive values, listed by name in `deploy.yml` under `env.secret`, values loaded from `.kamal/secrets` at deploy time

`.kamal/secrets` is a dotenv file evaluated in the shell context. Lines like `MY_SECRET=$MY_SECRET` pull values from the runner's environment.

Destination-specific secrets: `.kamal/secrets.{destination}` (loaded in addition to `.kamal/secrets`).

### Hooks

Lifecycle scripts in `.kamal/hooks/`: `pre-deploy`, `post-deploy`, `pre-build`, `pre-connect`, `docker-setup`, `pre-app-boot`, `post-app-boot`, `pre-proxy-reboot`, `post-proxy-reboot`.

## How to Learn More

Browse https://kamal-deploy.org/docs for any Kamal feature before using it. The official docs cover configuration, commands, hooks, and advanced features comprehensively.
