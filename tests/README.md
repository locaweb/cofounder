# Cofounder tests

Local-first test automation for the cofounder. See `ideas/test-plan.md` for the
full strategy (matrix, layers, harness adapter, determinism approach).

We climb the ladder one rung at a time, cheapest/most-deterministic first:

| Step | What | Needs | Status |
| ---- | ---- | ----- | ------ |
| **1** | `install.sh` Linux/WSL leg in clean podman containers (A0 tooling + A1 bootstrap + idempotency) | podman (local) | ✅ here |
| **2** | `preflight.sh` + `repo-init.sh` guard/sync branches in temp dirs | local | ✅ here |
| **4** | single-skill headless agent runs + LLM judge (harness adapter) | Claude CLI (local) | ✅ here |
| 3 | `install.sh` macOS leg | a clean Mac (tart/spare machine) | todo |

## Step 1 — run it

```bash
tests/install/test-install.sh
```

Builds a clean `ubuntu:24.04` image (no podman/mise/gh) and runs the local
working-tree `install.sh` inside it through:

- **A0** — tooling install on a clean machine, then an idempotent re-run.
- **A1** — project bootstrap: universal-only (no Claude), Claude-detected
  (`.claude/settings.json` + skills), idempotent re-run (no duplicated managed
  blocks / `.gitignore` entries), and a settings-merge that preserves user keys.

Each assertion prints `PASS`/`FAIL`; the run exits non-zero if any fail.

Notes:
- Tests the local `install.sh`; the *skills* it pulls come from the published
  `locaweb/cofounder` via `npx skills` (needs network).
- First run is slow (real apt installs + Playwright Chromium deps + `mise`
  fetching node); the image layer caches across runs.
- `ENGINE=docker tests/install/test-install.sh` to use Docker instead of podman.
- macOS-only behavior (Homebrew, `podman machine`) is **not** covered here — that
  is Step 3, on a real clean Mac.

## Step 2 — run it

```bash
tests/scripts/test-scripts.sh
```

Drives the bundled shell scripts in throwaway temp dirs on the host — offline,
fast, no container, no agent:

- **`preflight.sh`** — home-dir guard, existing-content guard, exempt content,
  empty/no-git, git-repo-no-remote, git-sync against a local bare remote (clean
  + dirty auto-commit/push), dev-tool detection, remote detection.
- **`repo-init.sh`** — offline guard branches (missing name, invalid visibility,
  not authenticated). The real `gh repo create` path is real-infra and is
  deferred to a dedicated test org (later).

## Step 4 — run it

```bash
tests/agent/test-agent.sh              # a2 (session start), 1 run
tests/agent/test-agent.sh a2 5         # a2, pass-rate over 5 runs
tests/agent/test-agent.sh e2e          # e2e scaffold from a fixed PRD, 1 run
tests/agent/test-agent.sh e2e 3        # e2e, pass-rate over 3 runs
```

Drives a **headless agent** on this machine. Per run it bootstraps a throwaway cofounder
project (real `install.sh`) with a local bare git remote — so pre-flight syncs
cleanly and does **not** trigger repo-setup (no GitHub side effects).

**a2 (session start)** — neutral greeting:
- deterministic asserts on the transcript: non-empty, `[Cofounder]` tag,
  pre-flight ran;
- LLM judge (`judge.sh`) for what greps can't prove: pre-flight ran *first*,
  persona + user's language (pt), and "asked what to build" (no PRD invented).

**e2e (scaffold)** — A4+A5, from the fixed PRD at `fixtures/prd-tasks.md`:
- deterministic asserts: `backend/`+`frontend/` exist, `go build ./...` compiles,
  `tsc -b` passes (the robust, hermetic backbone);
- LLM judge: implemented per PRD, ran Go + frontend tests *green*, followed stack
  conventions (sqlc/migrations/mise), and did **not** deploy;
- starts a podman DB container during the run; cleaned up (container + stray
  processes) after each run. Long (several minutes) and token-heavy.

Pieces (the reusable core for all future agent tests):
- `run-agent.sh` — harness adapter. Claude wired (`claude -p --output-format
  stream-json --permission-mode bypassPermissions`); codex/gemini/opencode are
  explicit stubs.
- `judge.sh` — LLM-as-judge, runs in a neutral cwd, emits `PASS`/`FAIL`.
- `test-agent.sh` — the A2 scenario + pass-rate loop.

Notes:
- **Spends tokens** (one agent run + one judge call per iteration) and is
  **non-deterministic** — hence the pass-rate loop rather than a single gate.
- Needs a Bash allow rule for the runner, since it spawns `bypassPermissions`
  subagents: add `Bash(tests/agent/test-agent.sh:*)` to `.claude/settings.local.json`.
- Wiring the other harnesses = filling in the stubs in `run-agent.sh`.

