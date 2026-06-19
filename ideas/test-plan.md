# Cofounder Test Plan

Status: draft / proposal · Date: 2026-06-19

A strategy for testing the cofounder end-to-end across environments and harnesses,
with an automation design that survives the non-determinism of AI agents and the
slowness of provisioning clean machines.

---

## 1. Goals & principles

1. **Test outcomes, not prose.** The agent's wording varies run-to-run; the
   filesystem, exit codes, build results, and a reachable URL do not. Every
   assertion targets a *deterministic side-effect* wherever possible.
2. **Push work down the pyramid.** Most of `install.sh` and the bundled scripts
   are deterministic shell — test them without an agent at all. Reserve costly
   agent runs for behavior that genuinely needs an agent.
3. **Reset, don't reinstall.** Golden images cloned per run (tart for macOS, a
   base tarball for WSL, containers for Linux) replace factory resets. Seconds,
   not hours.
4. **Sparse by design.** The matrix is large; most cells are redundant. Cover
   each axis once against a reference for the *other* axes, plus a few genuinely
   coupled intersections.
5. **Non-determinism is a measured SLA, not a blocker.** Agent scenarios run N
   times; we track pass-rate and alert on regressions instead of demanding a
   green/red single run.

---

## 2. Test dimensions & the sparse matrix

Three axes. The first two are the user's; the third ("what to test") is the
action the user performs.

### Axis E — Environment (machine state × OS, *coupled*)

State (clean vs. warm) and OS are **not** orthogonal — `install.sh` branches on
OS *and* on what is already present — so they form one coupled axis:

| Cell | OS | Machine state |
| ---- | -- | ------------- |
| **E1** | macOS (Apple Silicon) | clean — no brew/podman/mise/gh |
| **E2** | macOS | warm — tools pre-installed |
| **E3** | Windows + WSL2 (Ubuntu) | clean |
| **E4** | Windows + WSL2 (Ubuntu) | warm |
| *E5* | Linux container (Ubuntu/Debian/Fedora/Arch/Alpine/openSUSE) | clean | *(cheap proxy for E3, for fast L1 iteration)* |

### Axis H — Harness

| | |
| -- | -- |
| **H-claude** | reference harness (also the install/OS reference) |
| **H-codex** | OpenAI Codex |
| **H-opencode** | OpenCode |
| **H-gemini** | Gemini CLI |

### Axis A — Action scenario ("what to test")

| | Scenario | Determinism |
| -- | -------- | ----------- |
| **A0** | Tooling install (`install.sh` half 1) | deterministic |
| **A1** | Project bootstrap (`install.sh` half 2: skills, AGENTS.md/CLAUDE.md, settings, .gitignore) | deterministic |
| **A2** | Session start: pre-flight check + playbook activation + `[Cofounder]` persona | semi |
| **A3** | Repo setup: `gh auth` → create remote → push | semi |
| **A4** | Requirements → scaffold (Go+React app compiles, DB container up) | semi |
| **A5** | Local run + tests (Go + Vitest + `tsc -b`) + Playwright visual check | semi |
| **A6** | Feature iteration on an existing app | semi |
| **A7** | Deploy **preview** (real Locaweb Cloud infra) | semi + real infra |
| **A8** | Deploy **production** + custom domain | semi + real infra |
| **A9** | Operations: logs, SSH, DB access, scale, disaster recovery, SSH-key rotation | semi + real infra |

### Sparsity rules

- **E is orthogonal to H** (the user's insight): once tools exist, the agent
  behaves the same regardless of *how* they got there. So we do **not** run E×H
  fully (4×4=16). Instead:
  - **OS/install sweep:** run the full E axis against the **reference harness
    only** (H-claude). → `{E1,E2,E3,E4} × H-claude`.
  - **Harness sweep:** run the other three harnesses against the **single
    cheapest warm cell** (E4 / WSL-warm, or E5 container). → `E4 × {H-codex,
    H-opencode, H-gemini}`.
  - **Total agent environments: 7**, not 16.
- **E is coupled internally:** never test "clean" without its OS, or an OS only
  warm. All four E cells exist precisely because the combination matters.
- **A is layered on top:** not every action runs in every (E,H). Deterministic
  A0/A1 run on *all* E cells (they're cheap). Agent actions A2–A6 run on the 7
  agent environments. Real-infra A7–A9 run on **one** config on a slow cadence
  (cost + teardown risk).

### Concrete allocation

| Config | A0 | A1 | A2 | A3 | A4 | A5 | A6 | A7 | A8 | A9 |
| ------ | -- | -- | -- | -- | -- | -- | -- | -- | -- | -- |
| E1·claude (mac clean) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | — |
| E2·claude (mac warm)  | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ◐ | ◐ | ◐ |
| E3·claude (WSL clean) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — | — |
| E4·claude (WSL warm)  | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — |
| E4·codex              | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — |
| E4·opencode           | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — |
| E4·gemini             | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | — |
| E5·* (containers, L1) | ✓ | ✓ | — | — | — | — | — | — | — | — |

✓ = in scope · ◐ = real-infra, slow cadence (nightly/weekly), one config only ·
— = intentionally skipped (covered by an orthogonal cell)

> Deploy (A7–A9) is pinned to **E2·claude** because it's the maintainer's
> primary daily setup; harness portability of deploy is asserted at the
> *script/config* layer (L2: generated Kamal + workflow files are identical
> regardless of harness), not by paying for 4× real deploys.

---

## 3. What to test — scenarios & assertions

Each scenario lists the **trigger** (scripted prompt or command) and the
**deterministic assertions** plus any **judge rubric** (LLM-graded, for required
behavior the filesystem can't prove).

### A0 — Tooling install (`install.sh` half 1)
- **Trigger:** run `install.sh` in `$HOME` (machine-only mode), clean cell.
- **Assert:** `command -v podman mise gh` all resolve (+ `brew` on macOS); podman
  machine running on macOS; Playwright Chromium deps present on Debian/Ubuntu;
  re-run is a no-op (idempotency) and prints the "tools ready" message.
- **OS branches to cover:** Homebrew path (macOS), apt/dnf/pacman/apk/zypper
  (Linux), `--memory 1024` when RAM<16GB, Rosetta-warning path.

### A1 — Project bootstrap (`install.sh` half 2)
- **Trigger:** run `install.sh` inside an empty project dir, warm cell.
- **Assert (deterministic):**
  - skills installed for the right targets (`.agents/skills/` always;
    `.claude/skills/` iff Claude home present; `.hermes/skills/` iff Hermes home);
  - `AGENTS.md` contains the `<!-- cofounder:begin/end -->` activation block;
  - `CLAUDE.md` contains the `@AGENTS.md` import (Claude only);
  - `.claude/settings.json` merges to `model: opus[1m]`, `defaultMode:
    acceptEdits`, Bash/Read/WebFetch allowed — **and preserves pre-existing
    user keys** (merge, not overwrite);
  - `.gitignore` gains the four skill/lock entries;
  - **idempotency + upsert:** running twice rewrites the managed block in place
    (no duplication); an *old-format* block is migrated.

### A2 — Session start
- **Trigger:** start headless agent with a neutral prompt ("hi").
- **Assert:** pre-flight script ran (look for its marker output / git-sync
  side-effects); version gate behaves (stub an older `plugin.json` → session
  blocks with the refresh instruction).
- **Judge rubric:** replies are prefixed `[Cofounder]`; pre-flight ran *before*
  any other action; language auto-detected (pt-BR default); asked permission
  before mutating anything.

### A3 — Repo setup
- **Trigger:** project with no remote → prompt "set up the repo".
- **Assert:** `git remote get-url origin` resolves; remote exists on the test
  GitHub org; initial commit pushed; visibility honored. (Use a dedicated test
  GitHub org + a pre-authenticated `gh` token in CI to skip the device-code flow;
  the device-code flow itself is tested separately/manually.)

### A4 — Requirements → scaffold
- **Trigger:** feed a **fixed PRD fixture** (same product every run, to cap
  variance) → "build this".
- **Assert:** `backend/` + `frontend/` exist; `mise x -- go build ./...` and
  `mise x -- npx tsc -b` succeed; `<repo>-db` podman container is up; migrations
  apply; `GET /up` returns 200 locally.

### A5 — Local run + tests + visual
- **Assert:** `mise x -- go test ./...` and `mise x -- npx vitest run` pass;
  `tsc -b` clean; app serves on its port; Playwright screenshot captured (and
  optionally judged for obvious layout breakage).

### A6 — Feature iteration
- **Trigger:** on a seeded app repo, "add feature X" (fixed).
- **Assert:** new handler + test + component + test exist; full test+build suite
  still green; commit pushed.

### A7 — Deploy preview · A8 — Production + domain · A9 — Operations
- **Assert (A7):** deploy workflow succeeds (`gh run watch`); `curl
  https://<ip>.nip.io/up` → 200; **teardown runs and the env is gone**.
- **Assert (A8):** prod workflow on a `v*` tag succeeds; custom domain resolves
  + serves valid Let's Encrypt TLS (use a dedicated test DNS zone with
  API-driven A records).
- **Assert (A9):** SSH with `~/.ssh/<repo>` works; `docker logs` reachable; DB
  `psql` reachable; scale edit re-deploys; `recover: true` restores; SSH-key
  rotation revokes the old key and the new one works.
- **Script-layer fallback (L2, harness-portable):** assert the *generated*
  `config/deploy*.yml`, `.kamal/secrets-*`, and `.github/workflows/deploy-*.yml`
  match expected structure — this is deterministic and proves deploy correctness
  for the 3 harnesses we don't pay to actually deploy.

---

## 4. How to automate

### 4.1 The test pyramid

| Layer | What | Agent? | Where it runs | Cadence |
| ----- | ---- | ------ | ------------- | ------- |
| **L0 Static** | shellcheck `install.sh`+scripts; validate `plugin.json` vs `COFOUNDER_VERSION` stamp; markdownlint SKILL.md; `npx skills` manifest lint | no | GH Actions | every push |
| **L1 install.sh** | run `install.sh` in clean **containers** per distro; assert tools + files + idempotency (§A0/A1) | no | GH Actions matrix (Linux) + 1 macOS runner | every push |
| **L2 Scripts** | drive `preflight.sh`, `repo-init.sh`, `inject-agents-md.sh` with fixtures; assert flags (`PREFLIGHT_PASSED`, `NEEDS_REPO_SETUP`…) + generated deploy/Kamal config structure | no | GH Actions | every push |
| **L3 Single-skill** | headless agent, one scripted prompt → assert artifacts + judge transcript (§A2/A3, one-shot A4) | yes | self-hosted (tart/WSL/container) | nightly, ×N |
| **L4 E2E journey** | scripted multi-turn conversation through A2→A6 (and A7 on cadence) | yes | self-hosted | weekly / on release tag |

L0–L2 are the highest-leverage: they cover the entire E axis (install + OS
branches + bootstrap) **deterministically and for free**, leaving agents to
prove only genuinely agentic behavior.

### 4.2 Harness adapter

A thin wrapper normalizes the four CLIs so scenarios are written once and run
across harnesses:

```
run_agent(harness, prompt, cwd, session?) -> { transcript, exit_code, files }
```

| Harness | Headless invocation |
| ------- | ------------------- |
| Claude  | `claude -p "<prompt>" --output-format stream-json --permission-mode acceptEdits` (or `--dangerously-skip-permissions` in throwaway sandboxes) |
| Codex   | `codex exec "<prompt>"` |
| Gemini  | `gemini -p "<prompt>" --yolo --output-format json` |
| OpenCode | `opencode run "<prompt>" --model <provider/model>` |

The adapter handles: auto-approval flags (so the run never stalls on a prompt),
JSON/stream parsing into a common transcript shape, and multi-turn sessions
(resume by session id). Auth/model env is injected per harness.

### 4.3 Environment provisioning — reset, don't reinstall

The user has spare Macs + a Windows box, factory-resettable. Use them as
**self-hosted runner hosts** that clone golden images, never as machines that get
reset per test.

| Cell | Mechanism | Reset cost |
| ---- | --------- | ---------- |
| **E1/E2 macOS** | [`tart`](https://tart.run) VMs on Apple Silicon. Two golden images: `mac-clean`, `mac-warm`. `tart clone` → run → `tart delete`. | seconds |
| **E3/E4 WSL** | golden distro tarball. `wsl --import ci-<id> <dir> base.tar` → run → `wsl --unregister ci-<id>`. Two tarballs: clean, warm. | seconds |
| **E5 Linux** | Docker/Podman images per distro. | instant |
| factory reset | only for periodic full-fidelity audits (quarterly), never routine. | hours |

Golden images are rebuilt on a schedule so "clean" tracks real OS updates. The
spare Macs each run a tart-backed self-hosted GH Actions runner; the Windows box
runs a WSL-backed runner; a Linux box/cloud runner handles containers.

### 4.4 Beating non-determinism

1. **Outcome assertions** (primary): filesystem, `git log`, `go build`/`tsc -b`,
   container up, `/up` 200, screenshot exists. Path-independent.
2. **LLM-as-judge** (for behavior the FS can't prove): feed transcript + a
   rubric to a grader model → `{pass, reason}`. Rubrics encode the playbook's
   non-negotiables (`[Cofounder]` tag, pre-flight-first, ask-before-infra-change,
   one-unit-of-work, preview-before-prod).
3. **Constrain inputs:** fixed PRD/feature fixtures, seeded repos, pinned models
   (settings.json already pins `opus[1m]`; pin model flags for the others) — less
   variance to absorb.
4. **Pass-rate SLA:** run each agent scenario **N=3–5×**; require ≥ threshold
   (e.g. 4/5). Store per-scenario pass-rate over time; a drop is the regression
   signal. This turns "agents are flaky" into a tracked metric.
5. **Structural, not exact, diffing** of generated code: assert shape ("a handler
   + its test exist and compile"), never byte-equality.

### 4.5 Orchestration & reporting

- **Scenarios as declarative YAML** (steps: prompt → expect-files →
  expect-judge-rubric), consumed by a small runner (Go fits the stack). The
  runner: select cells → provision (tart/WSL/container) → `install.sh` → drive
  the harness adapter → collect artifacts+transcripts → assert + judge →
  teardown → emit JUnit/JSON + a pass-rate dashboard.
- **CI topology:** L0–L2 on every PR (GitHub Actions, fast, deterministic); L3
  nightly across the 7 agent configs; L4 weekly + on release tags; A7–A9
  real-infra on the slowest cadence with mandatory teardown.

### 4.6 Real-infra deploy safety (A7–A9)

- Dedicated **Locaweb Cloud test account** with budget alarms.
- **Unique env names** per run (`ci-<run-id>`) for isolation.
- **Teardown is mandatory and runs on failure** (`always()`); a nightly sweeper
  deletes orphaned `ci-*` envs as a backstop against leaks.
- Dedicated **test DNS zone** with API-driven A records for the custom-domain
  (A8) test.
- Most runs stop at **preview**; prod+domain on a rare cadence.

---

## 5. Phased rollout

1. **Phase 1 — deterministic core (highest ROI).** L0 + L1 (container distro
   matrix + 1 macOS runner) + L2. Covers the entire E axis and `install.sh` OS
   branches with zero agent cost. *Catches the majority of real regressions.*
2. **Phase 2 — harness adapter + L3.** Single-skill headless runs across the 4
   harnesses on E4/E5; introduce the LLM-judge and pass-rate tracking.
3. **Phase 3 — L4 E2E (local).** Full A2→A6 journey, preview deploy stubbed or
   skipped; tart/WSL golden-image fleet on the spare machines.
4. **Phase 4 — real-infra A7–A9.** Test cloud account, teardown automation,
   sweeper, custom-domain DNS zone.

---

## 6. Open decisions

- **Real-infra depth:** automate real preview/prod deploys (Phase 4), or stop at
  the L2 config-structure assertions and keep deploy testing manual? (Cost +
  teardown risk vs. coverage.)
- **macOS in CI:** GitHub-hosted macOS runners vs. self-hosted tart on the spare
  Macs (Homebrew + podman-machine are heavy on hosted runners).
- **Judge model & rubric ownership:** which model grades transcripts, and where
  the rubric source-of-truth lives (likely alongside each SKILL.md).
- **Gemini status:** the Gemini harness path is still on a feature branch — gate
  H-gemini scenarios until it merges.
