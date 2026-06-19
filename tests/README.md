# Cofounder tests

Local-first test automation for the cofounder. See `ideas/test-plan.md` for the
full strategy (matrix, layers, harness adapter, determinism approach).

We climb the ladder one rung at a time, cheapest/most-deterministic first:

| Step | What | Needs | Status |
| ---- | ---- | ----- | ------ |
| **1** | `install.sh` Linux/WSL leg in clean podman containers (A0 tooling + A1 bootstrap + idempotency) | podman (local) | ✅ here |
| **2** | `preflight.sh` + `repo-init.sh` guard/sync branches in temp dirs | local | ✅ here |
| 3 | `install.sh` macOS leg | a clean Mac (tart/spare machine) | todo |
| 4 | single-skill headless agent runs + LLM judge | agent CLIs | todo |

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
  deferred to a dedicated test org (Step 4 / later).

