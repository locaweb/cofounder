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
  not authenticated). The real `gh repo create` + push path is now covered
  separately by the gated live test, `tests/repo/test-repo-setup-live.sh`
  (see "Live repo-setup" below).

## Live repo-setup — run it (gated real-infra)

```bash
tests/repo/test-repo-setup-live.sh
```

Exercises `repo-init.sh`'s real GitHub path against the live API, with
**guaranteed teardown** — the throwaway repo is hard-deleted in an EXIT trap,
even on failure. 11 asserts across two scenarios:

- **create + push** — fresh local repo → `gh repo create --private` → assert the
  repo exists on GitHub, is private, `origin` is set locally, the committed
  `README.md` reached the remote, and nothing is left unpushed;
- **idempotent re-run** — same dir again → "Remote 'origin' already set", exit 0,
  no duplicate creation;
- **teardown assertion** — deletes the repo and asserts it's gone.

Safe by construction: the repo is **private**, named uniquely per run
(`cofounder-citest-<epoch>-<rand>`), created under the authenticated user by
default (override with `COFOUNDER_TEST_GH_OWNER`), and deleted on exit.

Prereqs (else it **SKIPs** cleanly, exit 0): `gh` installed + authenticated, and
the **`delete_repo`** scope on the token for teardown —

```bash
gh auth refresh -h github.com -s delete_repo   # complete the browser Authorize step
```

Without `delete_repo` the test still runs create+rerun, but deliberately **fails**
the teardown assertion and leaves the repo (so a silent orphan can't pass). Not
covered: the "repo already exists on GitHub, fresh local clone with divergent
history" branch (repo-init's `pull --rebase || true` then `push` would reject a
non-fast-forward — a real script limitation, not exercised here).

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
- `run-agent.sh` — harness adapter. Wired: **Claude** (`claude -p
  --output-format stream-json --permission-mode bypassPermissions`), **OpenCode**
  (`opencode run --format json --dangerously-skip-permissions`, model =
  `$COFOUNDER_TEST_OPENCODE_MODEL`), **Codex** (`codex exec --json
  --dangerously-bypass-approvals-and-sandbox`, model = `$COFOUNDER_TEST_CODEX_MODEL`),
  and **agy** (Antigravity — gemini's successor; `agy -p
  --dangerously-skip-permissions`, model = `$COFOUNDER_TEST_AGY_MODEL`). A
  **gemini** arm exists but the old `gemini` CLI's free tier is discontinued
  (auth-dead) — use `agy` instead.
- agy has no JSON output, so the adapter reconstructs a stream-json transcript
  via `agy-transcript.py` (see "agy" note below).
- Pick the harness positionally: `tests/agent/test-agent.sh a2 opencode`
  (so it stays under the one Bash allow rule — no env-var prefix).
- `judge.sh` — LLM-as-judge, runs in a neutral cwd, emits `PASS`/`FAIL`.
- `agy-transcript.py` — rebuilds a stream-json transcript for agy from its
  SQLite trajectory store + printed prose (see the "agy" note below).
- `test-agent.sh` — the A2 scenario + pass-rate loop.

**agy (Antigravity) specifics.** agy reads project context from `AGENTS.md` and
loads per-workspace skills from `.agents/skills/` — which `install.sh` already
populates (its `npx skills --agent universal` target writes there), so the
cofounder runs under agy with **no installer change**. The wrinkle is output:
`agy -p` prints only the final prose and writes its real tool trace (skill
loads, shell commands) to a per-conversation SQLite "trajectory store" at
`~/.gemini/antigravity-cli/conversations/<id>.db` (protobuf blobs). The adapter
captures the prose, finds the DB this run created (new-since-snapshot, else
newest), and `agy-transcript.py` emits a synthetic stream-json transcript —
`{"text":…}` for prose, `{"name":…,"command":…}` for each command / skill view —
so the existing asserts and `distill()` work unchanged. (Those conversation DBs
are global and accumulate; they're outside the project so they don't dirty its
git, but nothing prunes them.)

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
- Adding a harness = a new case arm in `run-agent.sh` (+ its token in
  `test-agent.sh`'s harness arg-parse). claude/opencode/codex/agy are wired.

## Status & what's left (pick up here)

Snapshot for resuming in a fresh session. Everything below is on `main`.

### Implemented (all green, local)

| Layer | Command | Asserts |
| ----- | ------- | ------- |
| Step 1 — install.sh Linux/WSL | `tests/install/test-install.sh` | 27 |
| Step 2 — preflight.sh + repo-init.sh | `tests/scripts/test-scripts.sh` | 29 |
| Live repo-setup (gh repo create + push) | `tests/repo/test-repo-setup-live.sh` | 11 |
| Step 4 — a2 (session start) | `tests/agent/test-agent.sh a2 [harness] [runs]` | 4 |
| Step 4 — e2e (scaffold A4+A5) | `tests/agent/test-agent.sh e2e` | 6 |
| Step 4 — deploy (app-deploy config) | `tests/agent/test-agent.sh deploy` | 16 |
| Step 3 — install.sh macOS | `bash tests/install/test-install-macos.sh` (on a clean Mac) | ~25 |

Harness adapter (`run-agent.sh`): **claude** + **opencode** + **codex** + **agy**
wired and validated (a2 passes on all; codex a2 = **5/5**, agy a2 = **5/5** runs
green). **gemini** is auth-dead (free CLI tier discontinued) — use **agy** (its
Antigravity successor) instead.

### Skill coverage

- ✓ computer-setup (Linux **+ macOS**), pre-flight-check, playbook, tech-stack, testing
- ✓ repo-setup (guard branches **+ live `gh repo create` + push**, with teardown;
  divergent-history clone branch still untested)
- ◑ app-deploy (config generation tested; **live deploy not tested**)
- ◑ frontend-design (exercised in e2e, no design-quality assertion)
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
2. **Harness adapter — codex + agy DONE** (a2 5/5 each; see the reference note
   below). Remaining harness work, all optional: run `e2e`/`deploy` under
   codex/agy to record their pass-rates (only a2 is recorded). The old `gemini`
   CLI is auth-dead — superseded by `agy`.
3. **repo-setup real path.** ✅ DONE — `tests/repo/test-repo-setup-live.sh`
   (11/11 green) drives the real `gh repo create --private` + push under the
   authenticated user with guaranteed teardown (hard-delete in an EXIT trap;
   needs the `delete_repo` scope). Still untested: the "repo already exists on
   GitHub, fresh local clone with divergent history" branch (repo-init would hit
   a non-fast-forward reject). ← **NEXT TASK is now #4.**
4. **frontend-design** — add a design-quality check (e.g. an LLM-judge over a
   Playwright screenshot for obvious breakage), since e2e only exercises it.
5. **Real-infra (gated)** — app-deploy **live deploy** (A7/A8) + **ssh-key-rotation**.
   Need a Locaweb Cloud test account, unique `ci-<id>` env names, and
   **guaranteed teardown** (`always()`) + a nightly orphan sweeper. See
   `ideas/test-plan.md` §4.6.
6. **(optional) deterministic test asserts** — make e2e run `go test`/`vitest`
   itself against the live DB instead of trusting the agent's "tests pass"
   narration. Deferred (current approach accepted).

### Codex + agy — DONE (reference for how a new harness gets wired)

Both validated at **a2 = 5/5 runs green**. Two different output contracts:

**codex** (`run-agent.sh` codex arm): `codex exec --json
--dangerously-bypass-approvals-and-sandbox "$PROMPT"` (+ optional
`-m $COFOUNDER_TEST_CODEX_MODEL`). Emits JSONL on stdout: assistant text =
`{"type":"agent_message","text":"..."}` (the existing `"text":"..."` distill grep
catches it); actions = `{"type":"command_execution","command":"..."}` — codex has
**no** `"name"` tool key, so `judge.sh` `distill()` gained a **"Commands run"**
section grepping `"command":"..."`. The raw-file test-signal grep already scans
codex's `aggregated_output`, so e2e/deploy signals work unchanged.

**agy** (Antigravity, gemini's successor; `run-agent.sh` agy arm): `agy -p
"$PROMPT" --dangerously-skip-permissions` (+ optional `--model
$COFOUNDER_TEST_AGY_MODEL`). The interesting one — **no JSON output at all**:
- agy reads `AGENTS.md` and loads per-workspace skills from `.agents/skills/`,
  which `install.sh` already populates (its `npx skills --agent universal`
  target). So the cofounder runs under agy with **no installer change** — verified
  the agent loads `cofounder-playbook`/`-pre-flight-check` and runs `preflight.sh`
  first. (The empty global `~/.gemini/skills` is a red herring — project installs
  use `.agents/skills/`.)
- `agy -p` prints only the final prose; the real tool trace lives in a per-
  conversation **SQLite trajectory store** at
  `~/.gemini/antigravity-cli/conversations/<id>.db` (`steps.step_payload`,
  protobuf blobs — string-extractable: `"CommandLine":...`, `.agents/skills/...
  SKILL.md` paths, etc.).
- `agy-transcript.py` reconstructs a **synthetic stream-json** transcript the
  existing asserts/`distill()` consume unchanged: tool/command/skill events from
  the DB + the prose as narration. The adapter snapshots the conversation dir
  before the run and picks the new DB (else newest).
- **Two traps already paid for** (both about matching the Claude shape `distill()`
  expects): (1) emit **compact** JSON (`separators=(",",":")`) — `distill` greps
  `"text":"..."` with no space after the colon, so `json.dumps` defaults produce
  an empty digest → judge fails on everything. (2) Emit **one text event per
  line**, not one giant block — `distill` does `cut -c1-500` *per* text event, so
  a single long prose block loses its tail (e.g. the "what to build?" question)
  and the judge can't confirm it.

**agy prereqs:** `agy --version` works + authenticated (the GUI OAuth carries
over; startup `not logged into Antigravity` log lines are race noise — look for
`Auth succeeded` further down, and `agy models` returns a list). Needs `python3`
+ `sqlite3` (both present on the dev Mac).

Not yet pass-rate'd under codex/agy: `e2e` and `deploy` (only a2 was run).

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

