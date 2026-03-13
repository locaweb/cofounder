---
name: tech-stack
description: Go + React full-stack architecture with iterative local development. Use this skill when scaffolding a new app, adding features, fixing bugs, running the local dev loop, or when the user asks to "run the app locally", "run the app on my computer", "start the app", "rodar o programa", "rodar o app", "executar localmente", or any equivalent request to launch the application in their local environment. Covers project layout, database migrations, sqlc code generation, local Supabase/Postgres via Podman, Postgres extensions (pgmq, pg_cron, pgroonga, pgvector, pg_jsonschema, LISTEN/NOTIFY), and the write-test-repeat feedback cycle.
---

# Tech Stack

Go JSON API + React SPA served from a single binary and deployed as one container.

## Architecture

**Backend:** Go stdlib `net/http` router, `pgx/v5` for Postgres, `sqlc` for query generation, `slog` for logging, embedded SQL migrations via `go:embed`.

**Frontend:** Vite + React + TypeScript, shadcn/ui components, Tailwind CSS, React Router. When making frontend design decisions (layouts, styling, component aesthetics, UI polish), use the **frontend-design** skill for guidance on creating distinctive, production-grade interfaces.

## Project Layout

```
.
├── backend/
│   ├── cmd/server/main.go       # Entrypoint
│   ├── internal/
│   │   ├── config/              # Env var parsing
│   │   ├── database/
│   │   │   ├── migrations/*.sql # Embedded, forward-only
│   │   │   ├── queries/*.sql    # sqlc source
│   │   │   └── sqlc/            # Generated — do not edit
│   │   └── handler/             # HTTP handlers (JSON API)
│   ├── go.mod
│   ├── go.sum
│   └── sqlc.yaml
├── frontend/                    # Vite + React SPA
│   ├── src/
│   │   ├── components/ui/       # shadcn/ui (generated, editable)
│   │   └── pages/               # Route-level components
│   └── dist/                    # Build output (gitignored)
└── Dockerfile
```

Ensure the project `.gitignore` includes at least:

```
backend/cmd/server/server
frontend/dist/
frontend/node_modules/
.venv/
.env
.claude/launch.json
```

`backend/cmd/server/server` is the locally compiled Go binary produced by `go build`. It must not be committed.

`.claude/launch.json` is generated locally by Claude Code Desktop's Preview feature and contains platform-specific commands — it must not be committed.

`.env` holds **all** service connection strings and application secrets needed to run locally. It must **never** be committed. After creating or updating it, restrict permissions:

```bash
chmod 0600 .env
```

Example contents:

```env
DATABASE_URL=postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable
REDIS_URL=redis://localhost:6379
N8N_WEBHOOK_URL=http://localhost:5678/webhook
```

The Go backend reads these values via `os.Getenv()`. During local development, load the file before starting the server using `. .env` (POSIX dot syntax — not `source`, which is a bash builtin and may not work in all shells, particularly when commands run through `subprocess` or `with_server.py`):

```bash
set -a && . .env && set +a
```

This bridges the gap between local and deployed: locally `.env` provides the values; deployed, Kamal config provides them. The Go code stays the same (`os.Getenv("REDIS_URL")`).

#### Clear vs secret env vars in deployment

When translating `.env` entries to Kamal config for deployment, the agent must decide whether each env var is **clear** or **secret**:

- **Secret** — the URL contains a credential (password, API key, token). Goes in `env.secret` + `.kamal/secrets.<env>`. The credential is stored as a GitHub Secret, and the URL is derived in the secrets file. Example: `DATABASE_URL` contains `POSTGRES_PASSWORD`.
- **Clear** — the URL has no credentials. Goes in `env.clear` in the Kamal config. No GitHub Secret needed. Example: Redis without auth (`REDIS_URL: redis://redis:6379`).

The rule: **if the URL embeds a credential, it's a secret; otherwise it's clear.** When in doubt, make it a secret — it's safer and the only cost is a GitHub Secret entry.

In deployed environments, secrets are injected as environment variables by the deployment platform — see the **app-deploy** skill.

`mise.toml` should **not** be gitignored — it is committed to the repo so all developers use the same tool versions.

## Key Decisions

### Single-binary serving

The Go server handles everything: API routes under `/api/`, static assets under `/assets/`, and a catch-all that returns `index.html` for SPA routing. In development, Vite's dev server proxies API calls to the Go backend.

### Postgres first

PostgreSQL is the primary external service. Use Postgres-backed alternatives whenever possible:
- **Queues:** `pgmq` — lightweight message queue with visibility timeout, archive, and batch operations. See [references/pgmq.md](references/pgmq.md)
- **Pub/Sub:** `LISTEN`/`NOTIFY` — no extension needed; combine with a persistence layer for durability. See [references/notify-patterns.md](references/notify-patterns.md)
- **Caching:** unlogged tables
- **Scheduling:** `pg_cron` + `pg_net` — in-database cron plus async HTTP requests for triggering app endpoints on a schedule. **Do not use container-level cron.** See [references/pg-cron.md](references/pg-cron.md)
- **Search:** `pgroonga` — full-text search for all languages including CJK, with boolean queries, ranking, highlighting, and JSONB search. No configuration needed. When the app involves searchable content (products, articles, listings, messages, logs), **proactively propose adding search**. Falls back to native `tsvector`/`tsquery` only when a simpler built-in solution suffices for a single well-supported language. See [references/pgroonga.md](references/pgroonga.md)
- **Vectors:** `pgvector` — embeddings storage and similarity search with HNSW and IVFFlat indexes. See [references/pgvector.md](references/pgvector.md)
- **JSON validation:** `pg_jsonschema` — validate `json`/`jsonb` columns against JSON Schema via CHECK constraints. See [references/pg-jsonschema.md](references/pg-jsonschema.md)
- **Geospatial:** `postgis` — geometry types, spatial indexes, and geographic functions. See <https://postgis.net/>
- **HTTP from SQL:** `pg_net` — asynchronous HTTP/HTTPS requests from SQL; used with `pg_cron` for scheduled calls or from triggers for webhooks
- Other notable extensions: `pgjwt`, `pg_stat_statements`, `pgaudit`, `pg_hashids`

All 60+ bundled extensions from `supabase/postgres` are available.

When the application needs a capability that Postgres and its extensions cannot provide — a pre-built tool like n8n, a specialized system like Kafka, or a use case where a dedicated service is clearly superior — add it as an accessory. See [Local Services](#local-services) for running it locally and `docs/INFRASTRUCTURE.md` for recording it. At deployment time, each accessory gets its own VM (see the **app-deploy** skill).

### sqlc for all queries

All SQL lives in `backend/internal/database/queries/*.sql`. Run `cd backend && mise x -- sqlc generate` after changes. **Never write raw SQL strings in Go handler code.**

Always include `emit_json_tags: true` in `sqlc.yaml` so that generated Go structs include lowercase JSON tags (e.g., `json:"id"` instead of exporting `ID` as-is). Without this, the API returns PascalCase field names that don't match frontend expectations.

### Migrations at startup

Embedded SQL files applied in order before the server accepts traffic. Forward-only, numbered sequentially (`001_create_users.sql`, `002_add_tasks.sql`, …). Each migration should be idempotent where possible (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`).

The `go:embed` directive only accepts files in the same directory or subdirectories of the file that declares it — paths with `..` are rejected by the compiler. Place the embed directive in a Go file next to the `migrations/` directory (e.g., `backend/internal/database/migrate.go`), not in `cmd/server/main.go`.

### Database connection retry

The Go backend should retry the database connection at startup (up to 10 attempts, 1-second delay between each). This handles parallel startup — Preview starts all servers simultaneously, so the backend may come up before the database is ready — and is also good practice for production deployments.

```go
var pool *pgxpool.Pool
for i := range 10 {
    pool, err = pgxpool.New(ctx, os.Getenv("DATABASE_URL"))
    if err == nil {
        if err = pool.Ping(ctx); err == nil {
            break
        }
        pool.Close()
    }
    slog.Warn("database not ready, retrying", "attempt", i+1, "err", err)
    time.Sleep(time.Second)
}
if err != nil {
    slog.Error("failed to connect to database", "err", err)
    os.Exit(1)
}
```

### Real-time updates via SSE

The Go backend listens for Postgres `NOTIFY` events and holds open a standard HTTP response with `Content-Type: text/event-stream` for each connected client. The React frontend uses the browser's built-in `EventSource` API. SSE is preferred over WebSockets to avoid adverse proxy configurations.

## Deployment Constraints

These match the **app-deploy** skill requirements:

- Single container on **port 80** (controlled by `PORT` env var, defaulting to `8080` for local dev)
- Health check: **`GET /up` → HTTP 200**
- Database via `DATABASE_URL` (preferred) or individual `POSTGRES_*` env vars — **fail hard if missing**
- File storage at `BLOB_STORAGE_PATH` (e.g. `/data/blobs`) — configured via `env.clear` in `deploy.yml`
- PostgreSQL as the primary data store (with 60+ bundled extensions via `supabase/postgres`). If the application needs services beyond what Postgres provides, additional accessories can be added via the deploy skill's Kamal layer
- No ORMs, no JavaScript frameworks beyond React, no CSS preprocessors

## Dockerfile

Multi-stage: (1) build frontend with Node, (2) build Go binary, (3) minimal Alpine runtime with binary + `frontend/dist/` + CA certs. The Go binary embeds migrations; frontend assets are served from `/frontend/dist` on disk. The Node and Go versions in the Dockerfile must match the versions in `mise.toml` — check `mise.toml` before writing or updating the Dockerfile.

## Local Development

All tools are invoked via **mise** (set up by **computer-setup**) using the `mise x` command, which reads `mise.toml` and runs the tool at the pinned version without requiring shell activation. The database runs as a `supabase/postgres` container via **podman** (also set up by **computer-setup**), matching the production image.

> **Container naming convention:** Each project's database container is named `<repo_name>-db` (e.g., `myapp-db`), where `<repo_name>` is the basename of the project's root directory. This prevents collisions when multiple cofounder projects coexist on the same machine. Derive the name once at the start of the session and use it consistently for all `podman` commands.

> **Critical: `go.mod` lives in `backend/`, not in the project root.** All Go and sqlc commands (`mise x -- go run`, `mise x -- go build`, `mise x -- go test`, `mise x -- go mod tidy`, `mise x -- sqlc generate`) **must** execute from the `backend/` directory. Always include `cd backend &&` inside the `bash -c` string. When a command chain involves multiple layers of shell invocation (bash → go), prefer writing a small helper script instead of nesting everything in a single `bash -c` string — this avoids the most common source of repeated build failures.

### Project tool versions

On first setup (when `mise.toml` does not yet exist in the project root), create it manually:

```toml
[tools]
go = "1"
sqlc = "1"
python = "3.14"
node = "24"
jq = "1"
```

Then trust and install the tools:

```bash
mise trust
mise install
```

This `mise.toml` is committed to the repo, ensuring all developers use the same versions. To upgrade a version later, edit `mise.toml` and re-run `mise install`.

All tool invocations in this skill use the `mise x` command (e.g., `mise x -- go run ./cmd/server`). This runs the tool at the version specified in `mise.toml` without requiring shell activation hooks — it works reliably in Claude Code's non-interactive shell, in Preview's `launch.json`, and in any script context.

### 1. Start the database and local services

Before starting the container, check if any podman container is already using port 5432:

```bash
podman ps -a --format '{{.Names}} {{.Ports}}' | grep '5432'
```

If a container from **another project** is occupying the port, do
**not** force-stop it. Instead, inform the user:

> "The container `<other_name>` from another project is currently using port 5432. Could you please stop it with `podman stop <other_name>` so we can start this project's database?"

Wait for the user to confirm before proceeding.

```bash
# Derive the container name from the repo directory
CONTAINER_NAME="$(basename "$(pwd)")-db"

# Start supabase/postgres container (matching production image)
# Important: provide only the POSTGRES_PASSWORD environment variable. The database is started with both user and database name preset to `postgres`.
podman run -d \
  --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD=postgres \
  -p 5432:5432 \
  supabase/postgres:17.6.1.095

# Verify it's ready (uses container exec instead of pg_isready)
podman exec "$CONTAINER_NAME" pg_isready -U postgres
```

#### Local Services

When the application needs services beyond Postgres, run them as podman containers locally. Each service maps to an accessory that will be provisioned as a dedicated VM in deployment.

#### Naming convention

Every project container is named `<repo_name>-<accessory_name>`:

```
myapp-db
myapp-redis
myapp-n8n
```

The `-db` convention already exists for Postgres. Extend it to all accessories. This enables the cleanup pattern (see [Stopping all project containers](#stopping-all-project-containers)).

#### Start-or-create pattern

Containers persist across sessions. On a fresh session the containers from the previous session may already exist (stopped). Always use the start-or-create pattern instead of a bare `podman run`:

```bash
podman start myapp-redis 2>/dev/null || \
  podman run -d --name myapp-redis -p 6379:6379 redis:7-alpine
```

`podman start` succeeds silently if the container exists (running or stopped). If it doesn't exist, the fallback `podman run` creates it. This prevents "name already in use" errors on session resume.

#### Two accessory types

Distinguish backend-connected and standalone accessories with different procedures:

**Backend-connected** (Redis, Kafka, Meilisearch, etc.):

1. Start-or-create the container with naming convention and port mapping
2. Readiness check (e.g., `podman exec <name> redis-cli ping`)
3. Add env var to `.env` (e.g., `REDIS_URL=redis://localhost:6379`)
4. Add Go client library, read env var via `os.Getenv()`
5. Record in `docs/INFRASTRUCTURE.md`

**Standalone** (n8n, WordPress, Metabase, etc.):

1. Start-or-create the container with naming convention, port mapping, and local directory mount if persistence matters
2. Readiness check (e.g., `curl -s http://localhost:5678/healthz`)
3. Give the user a clickable `http://localhost:<port>` link
4. Record in `docs/INFRASTRUCTURE.md`
5. No Go code changes unless the backend also calls the tool's API — see "Hybrid accessories" below

#### Hybrid accessories

Some accessories are both user-facing AND called by the backend. For example, n8n where the user manages workflows in the n8n UI, but the Go backend triggers workflows via webhook.

For hybrid accessories:
- Treat as standalone for the user-facing aspect (give the browser link)
- ALSO add a backend env var for the API endpoint (e.g., `N8N_WEBHOOK_URL=http://localhost:5678/webhook`)
- Record the env var in `docs/INFRASTRUCTURE.md`
- The Type column can remain `standalone` — the env var in the Env Var column signals the backend dependency

#### Port conflict detection

Same pattern as the existing Postgres port check: before starting a container, check if another podman container is already occupying the port using `podman ps -a --format '{{.Names}} {{.Ports}}' | grep '<port>'`. If the container belongs to another project, ask the user to stop it.

#### Common recipes

| Accessory | Image | Port | Readiness check |
|-----------|-------|------|-----------------|
| Redis | `redis:7-alpine` | 6379 | `podman exec <name> redis-cli ping` |
| n8n | `n8nio/n8n:latest` | 5678 | `curl -s http://localhost:5678/healthz` |
| Meilisearch | `getmeili/meilisearch:latest` | 7700 | `curl -s http://localhost:7700/health` |
| WordPress | `wordpress:latest` | 8080 | `curl -s http://localhost:8080` |
| WAHA | `devlikeapro/waha:latest` | 3000 | `curl -s http://localhost:3000/api/health` |

These are starting points. The agent should check the image's documentation for the correct ports and readiness endpoints.

#### Local vs. deployed hostnames

| Service | Local (`.env`) | Deployed hostname |
|---------|---------------|-------------------|
| Postgres | `localhost:5432` | `db:5432` |
| Redis | `localhost:6379` | `redis:6379` |
| n8n | `localhost:5678` | `n8n:5678` |

Locally, all services are on `localhost` with mapped ports. In deployment, each accessory gets its own VM. The deployed hostname matches the **accessory name** — CloudStack internal DNS resolves it to the VM's private IP within the isolated network (see [env-vars.md — Database Connection Variables](references/env-vars.md#database-connection-variables) for the documented pattern). Never use public IPs for inter-service communication.

The `.env` file (local) and Kamal config (deployed) each provide the correct values; the Go code reads them identically via `os.Getenv()`. For clear env vars (no credentials), the deployed value goes in `env.clear`. For secret env vars (with credentials), the deployed value goes in `.kamal/secrets` — see the `.env` section above.

### 2. Start the Go API (terminal 1)

```bash
bash -c 'set -a && . .env && set +a && cd backend && DEV_MODE=1 mise x -- go run ./cmd/server'
```

### 3. Start the Vite dev server (terminal 2)

```bash
bash -c 'cd frontend && mise x -- npm install && mise x -- npm run dev'
```

Access the app at `http://localhost:5173` during development. Vite proxies `/api/*` and `/auth/*` to the Go backend.

### Stopping all project containers

```bash
REPO_NAME="$(basename "$(pwd)")"

# Stop and remove all containers for this project
podman ps -a --filter "name=^${REPO_NAME}-" --format '{{.Names}}' | xargs -r podman stop
podman ps -a --filter "name=^${REPO_NAME}-" --format '{{.Names}}' | xargs -r podman rm
```

This relies on the naming convention (`<repo_name>-<accessory_name>`) and removes all project containers at once.

## Preview (Claude Code Desktop)

When `preview_*` tools are available (Claude Code Desktop), Preview manages the dev servers automatically — you do not need to start or stop them manually. Use `preview_screenshot`, `preview_click`, and `preview_snapshot` for quick visual checks during development. Reserve Playwright (via the **webapp-testing** skill) for comprehensive E2E test suites.

> **Windows:** Do not use the Preview tool on Windows. Use Playwright via the **webapp-testing** skill for visual verification instead.

#### Accessories in Preview mode

Preview manages the Go backend and Vite dev server automatically, but does **not** manage podman containers. Before using Preview, ensure all accessory containers are running:

```bash
REPO_NAME="$(basename "$(pwd)")"
podman start "${REPO_NAME}-db" || true
podman start "${REPO_NAME}-redis" || true  # if applicable
```

Check `docs/INFRASTRUCTURE.md` for the full list of accessories. If a container doesn't exist yet, create it first following the Local Services recipes above.

#### Environment variables in Preview

The Go backend command in `.claude/launch.json` must load `.env` so that all service URLs (DATABASE_URL, REDIS_URL, etc.) are available. When generating or updating launch.json, use the same `. .env` pattern as the CLI command, and **always prefix tool commands with `mise x --`**. Preview spawns processes directly without a shell profile, so tools installed by mise are only reachable through `mise x` (which reads `mise.toml` from the project root):

```
set -a && . .env && set +a && cd backend && DEV_MODE=1 mise x -- go run ./cmd/server
```

For the frontend entry in launch.json:

```
cd frontend && mise x -- npm run dev
```

This ensures Preview and CLI modes use the same env var source and the same tool resolution, and adding a new accessory only requires updating `.env` — not rewriting launch.json.

## Local Development Feedback Loop

> **Preview mode:** If you have access to `preview_*` tools (Claude Code Desktop), Preview manages the dev servers — **do not start them manually**. Use `preview_screenshot`, `preview_snapshot`, and `preview_click` for visual verification instead of Playwright for quick checks. Use Playwright (via the **webapp-testing** skill) for comprehensive E2E test suites.
>
> **Windows:** Do not use the Preview tool on Windows. Skip the Preview branch below and use Playwright via the **webapp-testing** skill.

The core workflow is: **write code → spin up local instance → run tests → repeat until the feature works → commit & push.**

```
┌──────────────────────────────────────────────────────┐
│                                                      │
│   Write / Edit Code                                  │
│        │                                             │
│        ▼                                             │
│   preview_* tools available?                         │
│     Yes (not Windows) ──► Preview manages servers    │
│     No / Windows ──► Start services manually         │
│             (podman supabase, go run, npm dev)       │
│        │                                             │
│        ▼                                             │
│   Run Backend Tests (Go)                             │
│        │                                             │
│        ▼                                             │
│   Visual / E2E Verification                          │
│     Preview mode: preview_screenshot + preview_click │
│     CLI / Windows: Playwright (webapp-testing skill) │
│        │                                             │
│        ▼                                             │
│   Tests pass? ──No──► Fix & repeat from top          │
│        │                                             │
│       Yes                                            │
│        │                                             │
│        ▼                                             │
│   Commit & push ──► Done                             │
│                                                      │
└──────────────────────────────────────────────────────┘
```

After committing and pushing, ask the user if they want to deploy to the cloud. If yes, use the **app-deploy** skill to run the **Deployment Feedback Loop**, which monitors the GitHub Actions workflow, verifies the health check, and handles deployment-specific failures.

### Backend testing (Go)

Run unit tests against the local database:

```bash
bash -c 'set -a && . .env && set +a && cd backend && DEV_MODE=1 mise x -- go test ./...'
```

- Test files live next to the code they test (`handler/todo_test.go` tests `handler/todo.go`).
- Use table-driven tests. Each test case gets a descriptive name.
- For database tests, use a test helper that runs migrations and wraps each test in a transaction that rolls back.
- Test the HTTP handlers via `httptest.NewServer` — send real HTTP requests, assert on status codes and JSON bodies.

### Frontend testing (Playwright)

Use the **webapp-testing** skill for Playwright-based end-to-end testing. The `with_server.py` helper manages the full stack:

```bash
mise x -- python skills/webapp-testing/scripts/with_server.py \
  --server "podman start $(basename $(pwd))-db || true" --port 5432 \
  --server "set -a && . .env && set +a && cd backend && DEV_MODE=1 mise x -- go run ./cmd/server" --port 8080 \
  --server "cd frontend && mise x -- npm run dev" --port 5173 \
  -- mise x -- python test_script.py
```

Note: use `. .env` (dot) instead of `source .env` — `with_server.py` may run commands under `/bin/sh`, where `source` is not available.

Or, if services are already running (with env vars already loaded), write a standalone Playwright script:

```python
from playwright.sync_api import sync_playwright

with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    page = browser.new_page()
    page.goto('http://localhost:5173')
    page.wait_for_load_state('networkidle')
    # ... test interactions
    browser.close()
```

Follow the reconnaissance-then-action pattern: screenshot → identify selectors → execute actions → assert results.

### sqlc workflow

Whenever SQL queries change:

```bash
bash -c 'cd backend && mise x -- sqlc generate'
```

Then update the Go code that calls the generated functions. Never hand-write SQL in Go files.

## Conventions

- **Thin handlers:** parse request → call database → return JSON. No business logic in handlers.
- **Logging:** `slog` exclusively. Never `fmt.Println` or `log.Println`.
- **Validation:** Server-side validation for all inputs. Never trust client-side validation alone.
- **Authorization:** Checks in every handler, not just middleware.
- **Frontend components:** `bash -c 'cd frontend && mise x -- npx shadcn@latest add <component>'`
- **No ORMs.** SQL through sqlc only.
- **No CSS preprocessors.** Tailwind CSS only.
- **No additional JavaScript frameworks.** React + React Router only.

## Authorization Best Practices

If the application has a user login area, **self sign-in with username and password** is acceptable for quickly prototyping the app, but **never for production** — the security of this method is weak.

**Recommended approach:** start with self sign-in (username + password) for prototyping, then move as soon as possible to one or both of:

- **Email with magic link** — practical, doesn't require memorization. Requires configuration of an SMTP gateway. See [references/smtp-gateway.md](references/smtp-gateway.md)
- **Google Auth** — practical, doesn't require memorization. Relies on Google's security mechanisms. Requires configuration of Google Auth (cost free). See [references/google-auth.md](references/google-auth.md)

## Dev Login for Testing

During local development, the agent (Playwright scripts or Claude Desktop Preview) needs to test pages behind authentication. Magic link and Google Auth flows cannot be completed in automated tests, so the backend must expose a **dev-only login endpoint** that bypasses the real auth flow.

### How it works

The backend registers a `POST /api/dev/login` route **only when `DEV_MODE=1`** is set. The guard must be at route registration time (not middleware) so the endpoint physically does not exist without the flag.

This endpoint accepts a user identifier (e.g., email), looks up the user, and creates a session using the exact same mechanism the real auth flow uses — same cookie name, same token format, same session store. The only difference is that it skips the external provider (magic link email or Google OAuth).

### Test user

The dev login handler should create the user on the fly if it doesn't already exist (`INSERT ... ON CONFLICT DO NOTHING`). This keeps the test user out of migrations, which run in all environments including production.

### Security

- The endpoint must **never** be registered when `DEV_MODE` is unset — enforced by the guard at route registration time.
- Production deployments must **never** set `DEV_MODE`. The deploy skill does not include it.

## Other References

- **[references/smtp-gateway.md](references/smtp-gateway.md)** -- SMTP gateway setup: Gmail (prototyping) and Locaweb (production) for sending e-mails (reminders, auth links, notifications, etc.)
- **[references/google-auth.md](references/google-auth.md)** -- Google Auth OAuth setup: Google Cloud Console configuration, consent screen, credentials

## Postgres Extension References

- **[references/pgroonga.md](references/pgroonga.md)** -- PGroonga full-text search: operators, ranking, highlighting, CJK support
- **[references/pgmq.md](references/pgmq.md)** -- pgmq message queue: SQL examples for send, read, archive, delete
- **[references/pg-cron.md](references/pg-cron.md)** -- pg_cron + pg_net: scheduled jobs, HTTP triggers, common patterns
- **[references/pgvector.md](references/pgvector.md)** -- pgvector similarity search: distance operators, HNSW/IVFFlat indexes, tuning
- **[references/pg-jsonschema.md](references/pg-jsonschema.md)** -- pg_jsonschema validation: CHECK constraint pattern, core functions
- **[references/notify-patterns.md](references/notify-patterns.md)** -- LISTEN/NOTIFY + persistence: pgmq for job queues, regular tables for data updates, polling fallback
