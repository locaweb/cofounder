# Cofounder tests

Local-first test automation for the cofounder. See `ideas/test-plan.md` for the
full strategy (matrix, layers, harness adapter, determinism approach).

We climb the ladder one rung at a time, cheapest/most-deterministic first:

| Step | What | Needs | Status |
| ---- | ---- | ----- | ------ |
| **1** | `install.sh` Linux/WSL leg in clean podman containers (A0 tooling + A1 bootstrap + idempotency) | podman (local) | ✅ here |
| **2** | `preflight.sh` + `repo-init.sh` guard/sync branches in temp dirs | local | ✅ here |
| **4** | single-skill headless agent runs + LLM judge (harness adapter) | Claude CLI (local) | ✅ here |
| **3** | `install.sh` macOS leg (A0 tooling + A1 bootstrap) | a clean Mac (tart/spare machine) | ✅ here (run on the Mac) |

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

## Step 3 — run it (on a clean Mac)

```bash
# copy the single self-contained file to a throwaway / brand-new Mac, then:
bash test-install-macos.sh
```

`tests/install/test-install-macos.sh` is the macOS counterpart of Step 1 — same
A0/A1 scenarios, but on the **host** (macOS can't be containerized). It is
**destructive to the host** (installs Homebrew + podman + mise + gh and inits a
podman machine; does not remove them) so it gate-confirms first and only cleans
the temp project dirs. Run it in your **own Terminal**, not inside Claude —
password and Rosetta prompts need to be answered interactively.

- Self-contained (assert helpers inlined) so you can `scp`/`curl` just this one
  file — no repo clone needed on the Mac.
- Runs the **published** one-liner's exact bytes (fetched once from the redirect,
  then driven from `$HOME` for A0 and temp dirs for A1). Override with
  `INSTALL_URL=…` or a local copy via `INSTALL_SH=/path`; `CONFIRM=1` skips the prompt.
- Mac-specific asserts Step 1 can't reach: `brew` + `/opt/homebrew` prefix,
  podman machine exists + running, the `<16GB → --memory 1024` branch, `$HOME`
  home-dir guard, and the idempotent "já está instalado / já está rodando" re-run.
- A1 here covers the **Claude-detected** path (`~/.claude` present pins
  `settings.json` + symlinks skills); the universal-only branch is Step 1's job.
- Rosetta is a GUI prompt — confirmed manually, not asserted.

## Step 4 — run it

```bash
tests/agent/test-agent.sh                 # a2 (session start), claude, 1 run
tests/agent/test-agent.sh a2 5            # a2, pass-rate over 5 runs
tests/agent/test-agent.sh a2 opencode     # a2 under OpenCode
tests/agent/test-agent.sh e2e             # e2e scaffold from a fixed PRD
tests/agent/test-agent.sh deploy          # app-deploy config generation (no real infra)
```

Args are positional: `test-agent.sh [scenario] [harness] [runs]` — scenario
`a2|e2e|deploy`, harness `claude|codex|gemini|opencode`.

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

**deploy (config-structure)** — app-deploy coverage **without real infra**, from
the pre-built-app fixture at `fixtures/deploy-app/`:
- drives the agent to generate the *preview* deploy config files only (Kamal
  config + secrets templates + GitHub Actions workflow) with placeholder creds;
- deterministic asserts on the generated files: `forward_headers: false`,
  `app_port: 80`, `/up`, `proxy ssl: true`, `nip.io` host, `provision.yml@v1`
  two-job workflow, `.kamal/secrets*` present;
- LLM judge: used placeholders, did **not** actually provision/deploy/create
  secrets/generate SSH keys;
- safe by construction: the project's remote is a local bare repo (no GitHub
  Actions), and provision/kamal would fail without real credentials. The live
  deploy itself stays gated behind a Locaweb test account (not covered here).

Pieces (the reusable core for all future agent tests):
- `run-agent.sh` — harness adapter. **Claude** (`claude -p --output-format
  stream-json --permission-mode bypassPermissions`) and **OpenCode** (`opencode
  run --format json --dangerously-skip-permissions`, model = configured default
  or `$COFOUNDER_TEST_OPENCODE_MODEL`) wired; codex/gemini are stubs.
- Pick the harness positionally: `tests/agent/test-agent.sh a2 opencode`
  (so it stays under the one Bash allow rule — no env-var prefix).
- `judge.sh` — LLM-as-judge, runs in a neutral cwd, emits `PASS`/`FAIL`.
- `test-agent.sh` — the A2 scenario + pass-rate loop.

### Watching a long run (per-minute progress)

The `e2e` scaffold takes several minutes. To follow it live instead of staring at
a blank terminal, run the test in the background and tail progress with
`watch-run.sh`, which prints a one-line snapshot per minute (transcript event
count, backend/frontend presence, DB status, the agent's latest action) and exits
when the run finishes.

Standalone:

```bash
tests/agent/test-agent.sh e2e > /tmp/e2e.out 2>&1 &
tests/agent/watch-run.sh /tmp/e2e.out
```

From Claude Code, the reproducible pattern is: launch the run with the Bash tool's
`run_in_background`, then point the **Monitor** tool at
`tests/agent/watch-run.sh <the run's output file>` — you get a chat notification
each minute and a `DONE` line at the end. `watch-run.sh` auto-discovers the newest
`cofoundertest.*` project and is macOS-safe (no `xargs -r`).

### Other notes

- **Spends tokens** (one agent run + one judge call per iteration) and is
  **non-deterministic** — hence the pass-rate loop rather than a single gate.
- Needs a Bash allow rule for the runner, since it spawns `bypassPermissions`
  subagents: add `Bash(tests/agent/test-agent.sh:*)` to `.claude/settings.local.json`.
- Wiring the other harnesses = filling in the stubs in `run-agent.sh`.

## Status & what's left (pick up here)

Snapshot for resuming in a fresh session. Everything below is on `main`.

### Implemented (all green, local)

| Layer | Command | Asserts |
| ----- | ------- | ------- |
| Step 1 — install.sh Linux/WSL | `tests/install/test-install.sh` | 27 |
| Step 2 — preflight.sh + repo-init.sh | `tests/scripts/test-scripts.sh` | 29 |
| Step 4 — a2 (session start) | `tests/agent/test-agent.sh a2 [harness] [runs]` | 4 |
| Step 4 — e2e (scaffold A4+A5) | `tests/agent/test-agent.sh e2e` | 6 |
| Step 4 — deploy (app-deploy config) | `tests/agent/test-agent.sh deploy` | 16 |
| Step 3 — install.sh macOS | `bash tests/install/test-install-macos.sh` (on a clean Mac) | ~25 |

Harness adapter (`run-agent.sh`): **claude** + **opencode** wired and validated
(a2 passes on both); **codex**/**gemini** are stubs.

### Skill coverage

- ✓ computer-setup (Linux), pre-flight-check, playbook, tech-stack, testing
- ◑ repo-setup (guard branches only — real `gh repo create` not tested)
- ◑ app-deploy (config generation tested; **live deploy not tested**)
- ◑ frontend-design (exercised in e2e, no design-quality assertion)
- ⬜ computer-setup **macOS** leg (Step 3)
- ⬜ ssh-key-rotation

### Remaining work, roughly ordered

1. **Step 3 — install.sh macOS leg.** ✅ Validated by hand on a clean Apple
   Silicon Mac (16 GiB, Claude detected): A0 tooling, A1 Claude-detected
   bootstrap, and a live agent run (playbook loaded first even when the opening
   message was an off-topic distraction; full pre-flight → repo-setup chain).
   `tests/install/test-install-macos.sh` captures the A0/A1 asserts for re-runs.
   Surfaced + fixed a brew UX bug (the `[y/n]` dependency prompt has no default —
   now suppressed with `HOMEBREW_NO_ASK=1`). Still unexercised: universal-only A1
   branch and Intel `/usr/local` prefix.
2. **Wire codex + gemini** in `run-agent.sh` (stubs today): `codex exec "<p>"`
   and `gemini -p "<p>" --yolo --output-format json`. Then run `a2`/`e2e`/`deploy`
   across them. Note: the judge distiller greps Claude/OpenCode JSON shapes
   (`"text"`/`"name"`) — re-check it against codex/gemini transcript formats.
3. **repo-setup real path** — `gh repo create` + push, against a dedicated test
   GitHub org (so it doesn't touch a real account). Today only the offline
   guard branches are covered.
4. **frontend-design** — add a design-quality check (e.g. an LLM-judge over a
   Playwright screenshot for obvious breakage), since e2e only exercises it.
5. **Real-infra (gated)** — app-deploy **live deploy** (A7/A8) + **ssh-key-rotation**.
   Need a Locaweb Cloud test account, unique `ci-<id>` env names, and
   **guaranteed teardown** (`always()`) + a nightly orphan sweeper. See
   `ideas/test-plan.md` §4.6.
6. **(optional) deterministic test asserts** — make e2e run `go test`/`vitest`
   itself against the live DB instead of trusting the agent's "tests pass"
   narration. Deferred (current approach accepted).

### Gotchas already paid for (don't rediscover)

- Agent runner needs the `Bash(tests/agent/test-agent.sh:*)` allow rule in
  `.claude/settings.local.json` (it spawns `bypassPermissions` subagents); adding
  it must be done by the user (the classifier blocks self-modification).
- This machine has **GNU coreutils** on PATH: `stat` is GNU (`-c %Y`, not `-f %m`),
  and `timeout`/`gtimeout` exist. `xargs -r` is *not* supported by BSD xargs.
- macOS mktemp dirs sit ~depth 5 under `/var/folders` (don't `-maxdepth 4`), and
  the Monitor shell doesn't export `TMPDIR`.
- The judge digest **drops file contents and tool args** (only narration + tool
  names + signal counts survive). Never put a fact in the judge rubric that (a) is
  already covered by a deterministic assert, or (b) only exists inside written
  files — the judge can't see it. See the `deploy` rubric note.
- Test-harness artifacts are gitignored inside throwaway projects so the
  cofounder's pre-flight auto-sync doesn't commit them.
- Real `skills/` changes need a `plugin.json` patch bump + `scripts/stamp-version.sh`
  (test-only changes don't).

