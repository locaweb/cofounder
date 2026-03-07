# Post-Deployment Operations

Reference for interacting with deployed infrastructure: finding IPs, SSH access, accessory access, container debugging.

## Finding Deployment IPs

Every deploy workflow run produces a `provision-output` artifact containing a JSON file with all IPs (see [workflows.md -- Deploy Output Reference](workflows.md#deploy-output-reference) for the full output spec). **Always clean up before downloading** to avoid reading stale data from a previous run:

```bash
# 1. Find the run ID for the environment you need
gh run list --workflow=deploy-preview.yml --limit=5

# 2. Clean up any previous artifact, then download
rm -rf /tmp/provision-output
gh run download <run-id> --name provision-output --dir /tmp/provision-output

# 3. Read the IPs
cat /tmp/provision-output/provision-output.json
```

The JSON contains:

| Key              | Description                                                        |
|------------------|--------------------------------------------------------------------|
| `web_ip`         | Public IP of the web VM -- used for SSH and app URL (`https://<web_ip>.nip.io`) |
| `worker_ips`     | JSON array of public worker VM IPs -- used for SSH                  |
| `accessory_ips`  | JSON object with accessory IPs. Each key is the accessory name (e.g., `db`, `redis`) with `ip` (public, SSH only) and `internal_ip` (private, used by the app) fields. |

Example `provision-output.json`:

```json
{
  "web_ip": "200.234.x.x",
  "worker_ips": ["200.234.y.y"],
  "accessories": {
    "db": {
      "ip": "200.234.z.z",
      "internal_ip": "10.1.1.x"
    },
    "redis": {
      "ip": "200.234.w.w",
      "internal_ip": "10.1.1.y"
    }
  }
}
```

### Fallback: get IPs from the workflow run summary

If you don't need the full JSON, the workflow run summary includes an IP table:

```bash
gh run view <run-id>
```

## SSH Access

**User is always `root`.** Use the SSH key that matches the environment. See [setup-and-deploy.md -- SSH Key Generation](setup-and-deploy.md#ssh-key-generation) for how these keys are generated.

### Resolve the key path first

Before any SSH command, determine the repo name and construct the key path. **Always use `-i` to specify the key** — never rely on the SSH client's default key selection:

```bash
# Get the repo name (without the owner prefix)
REPO_NAME=$(gh repo view --json name -q .name)

# Preview environment key
SSH_KEY=~/.ssh/$REPO_NAME

# Other environments (e.g., production)
SSH_KEY=~/.ssh/$REPO_NAME-production
```

### Key locations

| Environment | Key path |
|---|---|
| preview (default) | `~/.ssh/<repo-name>` |
| production | `~/.ssh/<repo-name>-production` |
| other `<env_name>` | `~/.ssh/<repo-name>-<env_name>` |

`<repo-name>` is the name of the GitHub repository (not the owner/org prefix).

### Connection commands

```bash
# Preview environment
ssh -i ~/.ssh/<repo-name> root@<web_ip>
ssh -i ~/.ssh/<repo-name> root@<accessory_ip>
ssh -i ~/.ssh/<repo-name> root@<worker_ip>

# Production (or other named environment)
ssh -i ~/.ssh/<repo-name>-production root@<web_ip>
ssh -i ~/.ssh/<repo-name>-production root@<accessory_ip>
ssh -i ~/.ssh/<repo-name>-production root@<worker_ip>
```

Use the accessory's `ip` field from the provision output for `<accessory_ip>`. For example, to SSH into the database VM: `root@<accessories.db.ip>`.

## Accessory Access

Each accessory runs inside a Docker container on its own VM. Accessory VMs only expose SSH (port 22) — service ports are **not** reachable from the public internet. You must SSH into the accessory VM first, then connect locally via `docker exec`.

The container name follows Kamal's naming convention: `<service-name>-<accessory-name>`. For example, a database accessory named `db` runs as `<repo-name>-db`.

### Understanding accessory IPs

- **`accessories.<name>.ip`** -- public IP, used for **SSH access** to the accessory VM
- **`accessories.<name>.internal_ip`** -- private IP on the CloudStack network. App containers connect to the accessory by its short hostname (e.g., `db`, `redis`) via CloudStack internal DNS — no IP needed.

### Example: connecting to PostgreSQL

The examples below use a Postgres accessory named `db`. The same pattern applies to any accessory — replace the `docker exec` command with what's appropriate for the service.

```bash
# 1. SSH into the accessory VM
ssh -i ~/.ssh/<repo-name> root@<accessories.db.ip>

# 2. Connect to Postgres via the container
docker exec -it <repo-name>-db psql -U postgres
```

### Run a one-off command

```bash
# From outside the accessory VM (combines SSH + docker exec)
ssh -i ~/.ssh/<repo-name> root@<accessories.db.ip> \
  'docker exec <repo-name>-db psql -U postgres -c "SELECT version();"'
```

## Container Debugging

After SSHing into a VM, use these commands to inspect running containers:

```bash
# List running containers
docker ps

# View web app logs (last 100 lines)
docker logs $(docker ps -q --filter "label=service=<repo-name>") --tail 100

# Follow logs in real time
docker logs $(docker ps -q --filter "label=service=<repo-name>") -f

# Check if the app responds locally
curl -s localhost:80/up

# View kamal-proxy logs (web VM only)
docker logs kamal-proxy --tail 50

# Check accessory container logs (e.g. Postgres on the db accessory VM)
docker logs <repo-name>-db --tail 100

# Check disk mounts
df -h /data    # web VM or accessory VM

# Check container environment variables
docker exec $(docker ps -q --filter "label=service=<repo-name>") env

# Open a shell inside the app container
docker exec -it $(docker ps -q --filter "label=service=<repo-name>") sh
```

## Common Pitfalls

### Stale artifact files

`gh run download` **does not** clean the target directory -- it merges files, and existing files cause a collision error or are silently kept. **Always** `rm -rf /tmp/provision-output` before downloading.

### Wrong SSH key for the environment

Each environment has its own SSH key. Using the preview key to SSH into a production VM (or vice versa) will fail with `Permission denied (publickey)`. Double-check the key path matches the environment.

### Accessory VMs have no externally exposed service ports

You cannot `psql -h <accessories.db.ip>` or `redis-cli -h <accessories.redis.ip>` from your local machine. Accessory VM firewalls only allow SSH (port 22). You must SSH in first, then use `docker exec` to reach the service.

### Getting the repo name

The repo name used in SSH key paths and container labels is the GitHub repository name (without the owner prefix). To confirm:

```bash
gh repo view --json name -q .name
```
