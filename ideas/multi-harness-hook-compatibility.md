# Multi-Harness Hook Compatibility (Claude, Codex, Gemini, Cursor, Hermes, Copilot)

Spec for making the cofounder `SessionStart` hook work across Claude Code,
OpenAI Codex, Google Gemini CLI, Cursor, Nous Research Hermes, and GitHub Copilot.

Date: 2026-06-06 (Hermes and Copilot added 2026-06-07)

> Note on paths: on this branch the plugin lives at `plugins/cofounder/`.
> On the root-level / restructured branches it lives at the repo root (so
> `hooks/hooks.json` instead of `plugins/cofounder/hooks/hooks.json`). Throughout
> this doc, `<plugin-root>/` means whichever of those applies in the branch you
> implement on. The hook script is `<plugin-root>/hooks/session-start-sync.sh`.

---

## 1. Goal

The hook config at `<plugin-root>/hooks/hooks.json` was written for Claude Code.
We want the same SessionStart behavior — sync `AGENTS.md`/`CLAUDE.md`, migrate
legacy installs, and inject the activation pointer — to fire under **Codex**,
**Gemini CLI**, **Cursor**, **Hermes**, and **GitHub Copilot** as well.

Several independent dimensions drive the work:

1. **Config format** — JSON for Claude/Codex/Gemini/Cursor/Copilot, **YAML** for Hermes.
2. **Schema shape** — top-level wrapper, event-name casing, and whether handlers
   nest under an inner `hooks[]` array or sit flat.
3. **Script-location mechanism** — does the variable the command relies on
   (`CLAUDE_PLUGIN_ROOT`) exist in each harness?
4. **Command execution model** — shell expansion (Claude/Codex/Gemini/Cursor) vs
   `shell=False` with no `${VAR}` expansion (Hermes). Copilot splits the command
   into per-OS `bash`/`powershell` keys.
5. **Project-dir handoff** — env var (`CLAUDE_PROJECT_DIR` & aliases), a JSON
   payload delivered on **stdin** (Hermes, Copilot), or an in-config `cwd`
   (Copilot, relative to the repo root).
6. **stdout-as-context** — whether the script's stdout is injected as session
   context (the activation pointer relies on this). Notably **ignored** for
   Hermes' `on_session_start`; unverified for Copilot's `sessionStart`.
7. **Timeout unit** — seconds everywhere (`timeout`, or Copilot's `timeoutSec`)
   except Gemini (**milliseconds**).

---

## 2. Current state (Claude)

`<plugin-root>/hooks/hooks.json`:

```json
{
  "description": "Keeps cofounder projects' AGENTS.md/CLAUDE.md in sync on every session start and migrates legacy agent-key installs to the injection model.",
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/session-start-sync.sh",
            "timeout": 15
          }
        ]
      }
    ]
  }
}
```

The config depends on three things:

- the nested shape `hooks → <Event> → [ { hooks: [ {…} ] } ]`
- `timeout` expressed in **seconds**
- the env var `${CLAUDE_PLUGIN_ROOT}` (the script `session-start-sync.sh` also
  *hard-requires* it via `${CLAUDE_PLUGIN_ROOT:?…}` on line ~20, and reads
  `CLAUDE_PROJECT_DIR`).

---

## 3. Compatibility assessment

### 3.1 Config syntax

| Aspect            | Claude               | Codex                 | Gemini                  | Cursor                              | Hermes                                       | Copilot                                          |
| ----------------- | -------------------- | --------------------- | ----------------------- | ----------------------------------- | -------------------------------------------- | ------------------------------------------------ |
| Format            | JSON                 | JSON ✅               | JSON ✅                 | JSON ✅                             | **YAML** ❌ different parser                  | JSON ✅ (one or more `*.json` files in a dir)     |
| Top-level wrapper | `hooks` object       | `hooks` ✅            | `hooks` ✅              | `version: 1` + `hooks` ⚠️ needs `version` | `hooks:` mapping ✅ (+ optional `hooks_auto_accept`) | `version: 1` + `hooks` ⚠️ needs `version`         |
| Event name        | `SessionStart`       | `SessionStart` ✅     | `SessionStart` ✅       | `sessionStart` ❌ camelCase         | `on_session_start` ❌ snake_case              | `sessionStart` ❌ camelCase                       |
| Group nesting     | `Event:[{hooks:[…]}]`| same ✅               | same ✅                 | `Event:[{command,…}]` ❌ flat, no inner `hooks[]` | `Event:[{command,…}]` ❌ flat (YAML list)     | `Event:[{…}]` ❌ flat, no inner `hooks[]`         |
| Handler keys      | `type,command,timeout`| `+statusMessage` ✅  | `+name,description` ✅  | `command,type,timeout,matcher,failClosed,…` | `command,matcher,timeout` (no `type`)        | `type,bash,powershell,cwd,env,timeoutSec` ❌ no `command` |
| `timeout` unit    | **seconds**          | **seconds** ✅        | **milliseconds** ❌     | **seconds** ✅                      | **seconds** ✅ (default 60, max 300)          | **seconds** ✅ `timeoutSec` (default 30)          |
| No `matcher` = all | ✅                  | ✅ (omit = all)       | ✅                      | ✅                                  | ✅ (`matcher` only for pre/post_tool_call)    | ✅ (no `matcher` documented for `sessionStart`)   |

### 3.2 Environment variables

The command and the script depend on `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PROJECT_DIR`.

| Var                  | Claude     | Codex                              | Gemini             | Cursor             | Hermes                              | Copilot                                  |
| -------------------- | ---------- | ---------------------------------- | ------------------ | ------------------ | ----------------------------------- | ---------------------------------------- |
| `CLAUDE_PLUGIN_ROOT` | ✅ native  | ✅ compat alias (+ `PLUGIN_ROOT`)  | ❌ **not provided** | ❌ **not provided** | ❌ **no env vars at all**            | ❌ not documented (`env` key can inject)  |
| `CLAUDE_PROJECT_DIR` | ✅         | ❌ (script falls back to `$PWD`)   | ✅ alias           | ✅ alias           | ❌ — `cwd` arrives via **stdin JSON** | ❌ — in-config `cwd` (rel. repo root) + stdin JSON |

**The central blocker is `CLAUDE_PLUGIN_ROOT`.** Only Claude and Codex set it
(and Codex only when the hook is loaded *as a plugin* — see §4.2). Under Gemini
and Cursor, `${CLAUDE_PLUGIN_ROOT}` expands to empty, the command becomes
`bash /hooks/session-start-sync.sh` (broken), and the script's
`${CLAUDE_PLUGIN_ROOT:?…}` hard-exits.

**Hermes is a different IO model entirely.** It passes *no* environment variables
to hooks. Instead each hook receives a JSON object on **stdin**
(`{ "hook_event_name", "session_id", "cwd", "extra": {…} }`), and the command runs
via `shlex.split(..., shell=False)` — so `${VAR}`/`$VAR` are never expanded and
shell operators don't work. The project directory is the `cwd` field of that
stdin payload, not an env var. See §4.4 and §5.5.

**Copilot** documents no project-dir/plugin-root env var either; it feeds hooks
"detailed information via JSON input" (stdin), and the config entry carries its
own `cwd` (relative to the repo root) and an optional `env` object for injecting
custom variables. The exact stdin fields are not documented — verify (§6). Since
`cwd` defaults to / is relative to the repo root, the script's `$PWD` fallback
should resolve the project dir. See §4.5 and §5.6.

### 3.3 Per-harness verdict

| Harness | Verdict |
| ------- | ------- |
| **Codex** | ✅ Works essentially as-is. Identical JSON shape, seconds-based timeout, `CLAUDE_PLUGIN_ROOT` provided for plugin-bundled hooks. |
| **Gemini** | ⚠️ Same shape, but needs timeout in **ms** and a plugin-root that doesn't exist. |
| **Cursor** | ❌ Needs a separate file with a different schema (`version`, lowercase event, flat entries) plus the plugin-root workaround. |
| **Hermes** | ❌ Most divergent. YAML at `~/.hermes/config.yaml`, snake_case `on_session_start`, no env vars (JSON-over-stdin), `shell=False` (no `${VAR}` expansion), and `on_session_start` stdout is **ignored** (no activation-pointer injection). Only the script's file side-effects work. |
| **Copilot** | ⚠️ Cursor-like JSON (`version:1`, `sessionStart`, flat) but its own keys: `bash`+`powershell` (no `command`), `timeoutSec`, in a `*.json` file under `.github/hooks/` (project) or `~/.copilot/hooks/` (user). No plugin-root env var; `cwd` is repo-relative so `$PWD` works. Cross-platform needs a `powershell` script too; `sessionStart` stdout-as-context is unverified. |

---

## 4. File layout decision

### 4.1 Differentiate by directory, not filename

Each harness discovers its config in its own namespaced location, so the
basename can stay `hooks.json`; only the directory changes.

| Harness | Discovery location                              | Filename        |
| ------- | ----------------------------------------------- | --------------- |
| Claude  | `<plugin-root>/hooks/hooks.json` (auto)         | `hooks.json`    |
| Codex   | `<plugin-root>/hooks/hooks.json` (same default) | `hooks.json`    |
| Cursor  | `.cursor/hooks.json`                             | `hooks.json`    |
| Gemini  | `.gemini/settings.json` → `"hooks"` key inside   | `settings.json` |
| Hermes  | `~/.hermes/config.yaml` → `hooks:` key inside    | `config.yaml`   |
| Copilot | `.github/hooks/*.json` (project) / `~/.copilot/hooks/*.json` (user) | `*.json` (any) |

### 4.2 Claude + Codex share one file

Codex's default plugin hook path is `hooks/hooks.json` at the plugin root —
exactly the Claude path. The schema and timeout units match, and Codex sets
`CLAUDE_PLUGIN_ROOT` for plugin-bundled hooks. So **one shared file serves
both**; do not rename it for Codex (renaming breaks Codex's default discovery).

Caveats to keep in mind:

- The top-level `description` key is not in Codex's documented schema. Expected
  to be ignored as a harmless annotation; verify on first run.
- Codex only sets `CLAUDE_PLUGIN_ROOT` when it loads the file **as a plugin**
  (`hooks/hooks.json` at the plugin root, or via a `.codex-plugin/plugin.json`
  manifest). If instead someone wires it as a repo-local `.codex/hooks.json`,
  the env var is NOT set. The self-locating script change in §5.1 removes this
  fragility.

### 4.3 Gemini has no standalone hooks file

Gemini reads hooks from a `"hooks"` block merged into `.gemini/settings.json`,
not from a dedicated `hooks.json`. So there is no separate filename to choose;
it's a section inside a different file.

### 4.4 Hermes is user-level YAML, not a packaged hooks file

Hermes declares hooks in the user's `~/.hermes/config.yaml` under a top-level
`hooks:` mapping. (The docs reference both `config.yaml` and `cli-config.yaml` —
resolve which is canonical before implementing.) There is no plugin/extension-
bundled hooks file and no project-local discovery documented. Consequences:

- **No packaging.** The hook can't ship *inside* the cofounder plugin; it must be
  written into `~/.hermes/config.yaml` at install time, and the script placed at a
  stable path (the docs' examples use `~/.hermes/agent-hooks/…`).
- **`shell=False`.** Hermes runs the command via `shlex.split(..., shell=False)`,
  so `${VAR}`/`$VAR` are **not expanded** and shell operators (`||`, `2>`, …) do
  not work. The command must be a literal, already-resolved path. (Whether `~` is
  expanded is unverified — prefer an absolute path.)
- **stdin wire protocol, not env vars.** Each hook receives a JSON object on
  stdin: `{ "hook_event_name", "session_id", "cwd", "extra": {…} }`. The project
  directory is the `cwd` field of that payload, not `$CLAUDE_PROJECT_DIR`.
- **First-use consent.** Hooks prompt for consent on first use unless
  `hooks_auto_accept: true` is set at the top level of the config.

### 4.5 Copilot uses a directory of JSON files, with per-OS scripts

Copilot discovers hooks from **every `*.json` file** in a directory — `.github/hooks/`
in the repo (project-level) or `~/.copilot/hooks/` (user-level) — rather than one
named file. Each file is `{ "version": 1, "hooks": { … } }`. Notable shape deltas:

- **No `command` key.** A handler specifies the script per-OS: `bash` (required on
  Unix) and `powershell` (required on Windows). The cofounder script is bash-only,
  so a Windows Copilot run needs a `powershell` counterpart (or a bash available
  via WSL/Git-Bash) — a real cross-platform gap, not just a config rename.
- **In-config `cwd` and `env`.** The entry can set `cwd` (relative to repo root)
  and an `env` object. This is the one harness that lets you inject an env var
  *from the config* — e.g. an explicit plugin-root path — without the harness
  providing one.
- **`timeoutSec`**, not `timeout`; seconds; default 30.
- **Project-level discovery is natural.** Because `.github/hooks/` lives in the
  repo, this is a per-project install (write the file into the target repo at
  install time), similar to Cursor's `.cursor/hooks.json`.

---

## 5. Implementation plan

### 5.1 Make the script self-locating (removes the `CLAUDE_PLUGIN_ROOT` dependency)

In `<plugin-root>/hooks/session-start-sync.sh`, replace the hard requirement:

```sh
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:?CLAUDE_PLUGIN_ROOT required}"
```

with a self-locating derivation that falls back to the env var only if needed:

```sh
# Resolve the plugin root from the script's own location so the hook works under
# harnesses that don't export CLAUDE_PLUGIN_ROOT (Gemini, Cursor). Honor an
# explicitly-set CLAUDE_PLUGIN_ROOT first for parity with Claude/Codex.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
```

(`session-start-sync.sh` lives in `<plugin-root>/hooks/`, so the plugin root is
its parent directory.) The rest of the script is unchanged: it already falls
back `PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"`, which works everywhere because
commands run with the session cwd as their working directory.

After this change, the command strings in the config files can still reference
`${CLAUDE_PLUGIN_ROOT}` on Claude/Codex, but should reference the script by a
path the harness can resolve on Gemini/Cursor — see below.

### 5.2 Claude + Codex — keep the shared file unchanged

`<plugin-root>/hooks/hooks.json` stays exactly as in §2. No edits required.
(Optional: drop `description` if Codex turns out to reject unknown top-level
keys — verify first.)

### 5.3 Gemini — `.gemini/settings.json`

Add a `hooks` block. Two deltas vs the Claude file: **timeout in milliseconds**
and **no `CLAUDE_PLUGIN_ROOT`** (use `$GEMINI_PROJECT_DIR`, or a project-relative
path, to locate the script — pick whichever matches how the plugin/extension is
installed). Example assuming the plugin sits at the project root:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$GEMINI_PROJECT_DIR/hooks/session-start-sync.sh\"",
            "timeout": 15000
          }
        ]
      }
    ]
  }
}
```

Notes:
- `15000` ms = 15 s (Claude's `15`). Do **not** copy `15` here — it would be 15 ms.
- Gemini exposes `GEMINI_PROJECT_DIR`, `GEMINI_PLANS_DIR`, `GEMINI_SESSION_ID`,
  `GEMINI_CWD`, and a `CLAUDE_PROJECT_DIR` alias — but **no** plugin root.
- Confirm where Gemini expects an *extension* to ship hooks (the
  `feat/gemini-extension` branch may already establish this); the command path
  must match the extension's installed layout.

### 5.4 Cursor — `.cursor/hooks.json`

Different schema: top-level `version`, **lowercase** `sessionStart`, and **flat**
entries (no inner `hooks` array — `command` sits directly on the array item).
Timeout is in seconds. No plugin root, so use `$CURSOR_PROJECT_DIR` (or the
`CLAUDE_PROJECT_DIR` alias):

```json
{
  "version": 1,
  "hooks": {
    "sessionStart": [
      {
        "type": "command",
        "command": "bash \"$CURSOR_PROJECT_DIR/hooks/session-start-sync.sh\"",
        "timeout": 15
      }
    ]
  }
}
```

Notes:
- Cursor exposes `CURSOR_PROJECT_DIR`, `CURSOR_VERSION`, `CURSOR_USER_EMAIL`,
  `CURSOR_TRANSCRIPT_PATH`, `CURSOR_CODE_REMOTE`, and a `CLAUDE_PROJECT_DIR`
  alias — no plugin root.
- `sessionStart` stdout-as-context behavior should be confirmed against the
  Cursor reference (the script relies on stdout being injected as session
  context for activation).

### 5.5 Hermes — `~/.hermes/config.yaml`

Hermes is the harness where the self-locating script (§5.1) is *necessary but not
sufficient*, because `on_session_start` stdout is discarded. Plan:

- **Write a `hooks` block** into `~/.hermes/config.yaml` at install time:

  ```yaml
  hooks:
    on_session_start:
      - command: "/absolute/path/to/session-start-sync.sh"
        timeout: 15
  ```

- **Use an absolute path** to the script — no `${VAR}`, no reliance on `~`
  expansion (`shell=False`). The self-locating change in §5.1 still lets the
  script find the plugin root from its own `BASH_SOURCE`.
- **Take the project dir from stdin**, not env. `session-start-sync.sh` currently
  does `PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"`; for Hermes it needs a branch
  that reads the stdin payload's `cwd` (e.g. `jq -r .cwd`) when present. *If*
  Hermes runs the hook with the process `cwd` already set to the project, the
  existing `$PWD` fallback suffices and no stdin parsing is needed — verify (§6).
- **The activation pointer will NOT inject** at session start: `on_session_start`
  stdout is **ignored**. Only `pre_llm_call` can inject context, via a stdout JSON
  `{"context": …}` key. So on Hermes the hook performs only its file side-effects
  (AGENTS.md sync, migration). Decide separately whether Hermes loads `AGENTS.md`
  natively for the instruction content, and whether a `pre_llm_call` shim is worth
  adding just to deliver the pointer.

### 5.6 Copilot — `.github/hooks/cofounder.json`

Closest to Cursor, but with per-OS script keys and an in-config `cwd`/`env`. Plan:

- **Write a project-level file** `.github/hooks/cofounder.json` at install time:

  ```json
  {
    "version": 1,
    "hooks": {
      "sessionStart": [
        {
          "type": "command",
          "bash": "bash ./path/to/session-start-sync.sh",
          "powershell": "bash ./path/to/session-start-sync.sh",
          "cwd": ".",
          "timeoutSec": 15
        }
      ]
    }
  }
  ```

- **Locate the script via `env` or a repo-relative path.** Two options: (a) point
  `bash` at a path relative to `cwd` (repo root), or (b) use the `env` object to
  inject an explicit root (e.g. `"env": { "CLAUDE_PLUGIN_ROOT": "…" }`) and keep
  the Claude-style command. The self-locating script (§5.1) makes either robust.
- **Project dir** is the repo root (default `cwd`), so the script's `$PWD`
  fallback resolves it — no stdin parsing strictly required, though Copilot also
  delivers a JSON stdin payload (fields undocumented — verify §6).
- **Windows.** `powershell` is required on Windows; the bash-only script needs a
  PowerShell wrapper or a guaranteed `bash` (WSL/Git-Bash). Decide whether Copilot-
  on-Windows is in scope before shipping.
- **Activation pointer.** Whether `sessionStart` stdout is injected as context is
  not documented — verify (§6); if not, Copilot gets file side-effects only, like
  Hermes.

---

## 6. Open questions / verification checklist

- [ ] Does Codex silently ignore the top-level `description` key? (§4.2)
- [ ] Confirm Codex actually loads `<plugin-root>/hooks/hooks.json` and sets
      `CLAUDE_PLUGIN_ROOT` in the chosen install path; otherwise rely on the
      self-locating script (§5.1).
- [ ] Confirm Gemini's extension install layout and the correct command path
      (cross-check `feat/gemini-extension`).
- [ ] Confirm Cursor injects `sessionStart` stdout as agent context (needed for
      the activation pointer the script echoes).
- [ ] Verify the self-locating script resolves correctly under each harness's
      working directory and symlink handling.
- [ ] Decide whether these per-harness configs ship inside the plugin or are
      written into a target project at install time (the computer-setup /
      install flow).
- [ ] Hermes: confirm the canonical config file name (`config.yaml` vs
      `cli-config.yaml` — the docs reference both) and whether any project-local
      config is supported (vs only user-level `~/.hermes/`).
- [ ] Hermes: confirm whether the hook process `cwd` is set to the project dir
      (lets the `$PWD` fallback work) or whether the script must parse `cwd` from
      the stdin JSON payload.
- [ ] Hermes: confirm whether `~` is expanded in `command` (else require an
      absolute script path; `shell=False` means no `$VAR`/`~` shell expansion).
- [ ] Hermes: decide how (or whether) to deliver the activation pointer given
      `on_session_start` stdout is ignored — accept file-only side-effects, or add
      a `pre_llm_call` `{"context": …}` shim.
- [ ] Copilot: confirm the stdin JSON payload fields (session id, cwd, etc.) and
      whether `sessionStart` stdout is injected as agent context.
- [ ] Copilot: confirm how `bash`/`powershell` script paths resolve (relative to
      `cwd`/repo root vs absolute) and what `cwd: "."` is relative to.
- [ ] Copilot: decide Windows scope — `powershell` is required there and the
      cofounder script is bash-only.
- [ ] Copilot: decide project-level (`.github/hooks/`) vs user-level
      (`~/.copilot/hooks/`) install, and whether to inject the plugin root via the
      `env` key vs the self-locating script.

---

## 7. Summary

- **Codex**: shares Claude's `hooks/hooks.json` unchanged.
- **Gemini**: add a `hooks` block to `.gemini/settings.json`, timeout in **ms**,
  locate the script via `$GEMINI_PROJECT_DIR`.
- **Cursor**: add `.cursor/hooks.json`, schema `version:1` + `sessionStart` +
  flat entries, locate the script via `$CURSOR_PROJECT_DIR`.
- **Hermes**: write a `hooks: { on_session_start: [...] }` block into
  `~/.hermes/config.yaml`; YAML, snake_case event, seconds timeout, **absolute**
  script path (no `${VAR}` — `shell=False`); the script must take the project dir
  from the **stdin JSON `cwd`**; the activation-pointer stdout is **ignored**
  (file side-effects only, unless a `pre_llm_call` shim is added).
- **Copilot**: write `.github/hooks/cofounder.json` (`version:1` + `sessionStart`,
  flat); use `bash`/`powershell` keys + `timeoutSec`; `cwd` is repo-relative so
  `$PWD` resolves the project; locate the script via a repo-relative path or the
  in-config `env`; mind the Windows `powershell` requirement.
- **Cross-cutting**: make `session-start-sync.sh` self-locating so it no longer
  depends on `CLAUDE_PLUGIN_ROOT`, which only Claude and Codex provide — and make
  it source the project dir from `$CLAUDE_PROJECT_DIR` → `$PWD` → stdin `cwd`
  (Hermes) so it works regardless of how each harness hands off the project path.

---

## 8. Source documentation (official)

Each harness's hook spec, as used for the claims above. Verify against these
before implementing — the per-harness details here are only as current as the
fetch dates noted.

| Harness | Official hooks documentation |
| ------- | ---------------------------- |
| **Claude Code** | <https://code.claude.com/docs/en/hooks> |
| **OpenAI Codex** | <https://developers.openai.com/codex/hooks> |
| **Gemini CLI** | <https://github.com/google-gemini/gemini-cli/blob/main/docs/hooks/reference.md> (canonical repo docs; `geminicli.com` is a third-party mirror) |
| **Cursor** | <https://cursor.com/docs/hooks> |
| **Hermes** | <https://hermes-agent.nousresearch.com/docs/user-guide/features/hooks> |
| **GitHub Copilot** | <https://docs.github.com/en/copilot/concepts/agents/hooks> |

> Hermes and Copilot details were captured from the above on 2026-06-07. The
> Claude/Codex/Gemini/Cursor rows predate this doc; re-check the live pages
> (especially Gemini's timeout unit and Cursor's exact `sessionStart` schema)
> when implementing §5.

---

## 9. Rollout plan (phased, with progress tracking)

Live clients today are **all Claude**, so this rolls out incrementally: one
behaviour-neutral foundation change first, then one harness at a time, in the
order **Cursor → Codex → Copilot → Gemini → Hermes**. **Each phase is merged to
`main` and tested before the next begins.** Phase 0 must not change observable
Claude behaviour; every later phase is purely additive — a new per-harness config
file — and leaves the Claude runtime path untouched.

Legend: `[ ]` todo · `[~]` in progress · `[x]` done. Update these boxes as work
lands so progress survives across sessions. Work happens on
`feat/multi-harness-hooks`; each phase lands on `main` via its own focused merge.

### Phase 0 — Universal foundation (Claude-neutral) — `[x]`

Goal: remove the hard dependency on Claude-specific env vars so the same scripts
and skills run under any harness, **without changing what Claude does**. This is
the §5.1 recipe applied across the bundled scripts.

Resolution mechanism chosen (supersedes parts of §5.1/§6):

- **Real script files self-locate via `${BASH_SOURCE[0]}` — universally, with NO
  harness var.** Bash always sets `BASH_SOURCE` to the executing file's own path,
  so the hook and bundled scripts find the plugin root the same way under every
  harness. We do **not** prefer `CLAUDE_PLUGIN_ROOT` (nor rely on Codex's compat
  aliases) — `BASH_SOURCE` is the single mechanism, Claude included.
- **Skills can't self-locate (an inline `SKILL.md` command has no `BASH_SOURCE`
  anchor and runs with cwd = project).** All target harnesses implement the agent
  skills standard and read `SKILL.md`, so instead of any `${VAR}` substitution the
  `SKILL.md` gives the executable as a path **relative to the `SKILL.md`'s own
  directory** and leaves it to the agent to resolve and run it (the agent already
  knows where it loaded the skill from). Harness-agnostic by construction.

- [x] Make `hooks/session-start-sync.sh` self-locating via `${BASH_SOURCE[0]}`
      with no harness-var dependency at all. Replaced the `${CLAUDE_PLUGIN_ROOT:?…}`
      hard-require. (§5.1)
- [x] Confirm project-dir sourcing is already harness-neutral
      (`PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"` — no change now; stdin `cwd`
      is added in Phase 5 for Hermes).
- [x] Make `scripts/inject-agents-md.sh` self-locating via `${BASH_SOURCE[0]}`;
      `$2` still honoured as an explicit override when present.
- [x] Verify `preflight.sh` and `repo-init.sh` need no root passed in (they only
      need to be invoked); neither references `CLAUDE_PLUGIN_ROOT`, so no change.
- [x] Update the three skills (`pre-flight-check`, `install`, `repo-setup`) to
      reference their bundled script by a path **relative to the `SKILL.md`** and
      let the agent locate/run it — no `${VAR}` substitution. `pre-flight-check`
      and `repo-setup` use `scripts/<name>.sh`; `install` uses the shared
      plugin-root script `../../scripts/inject-agents-md.sh` (and drops the
      now-redundant root argument).
- [x] Prove Claude-neutral: verified the self-locating scripts produce identical
      results with no env vars set at all (AGENTS.md re-stamp, CLAUDE.md
      `@AGENTS.md` ref, non-cofounder projects stay silent). **Live-verified** by
      installing the branch as a local dev marketplace (detached worktree,
      version 0.21.13) in a real Claude session: (1) SessionStart hook fired and
      re-stamped a stale 0.0.0 project to 0.21.13, added the CLAUDE.md ref,
      preserved user content, and migrated the legacy `agent` key; (2) both skill
      locators resolved under the installed layout — `install` ran
      `../../scripts/inject-agents-md.sh`, `pre-flight-check` ran
      `scripts/preflight.sh` (NEEDS_REPO_SETUP + PREFLIGHT_PASSED).
- [x] **Merge to `main` before Phase 1.** (Live-client verification done above.)
      Landed on `main` as merge commit `7127904`, published version 0.21.13.

> **Known gap surfaced during Phase 0 (not yet planned):** the install skill
> writes `.claude/settings.json` (model pin + permission allowlist + acceptEdits),
> which is Claude-Code-only — other harnesses ignore it. The cross-harness
> `AGENTS.md` "ask the user to allow actions" instruction is the working fallback;
> a per-harness project-config equivalent (Cursor/Gemini/Codex/…) is a future
> enhancement, parallel to the per-harness hook configs. (Also: `.claude/settings.json`
> is a protected path — under Claude *auto mode* the install's write is routed to
> the classifier and may be blocked; default mode prompts normally.)

### Phase 1 — Cursor — `[ ]`

- [ ] Add `.cursor/hooks.json` (§5.4): `version:1`, `sessionStart`, flat entries,
      seconds timeout; locate the script via `$CURSOR_PROJECT_DIR` / self-location.
- [ ] Decide ship-in-plugin vs write-at-install (§6).
- [ ] Confirm Cursor injects `sessionStart` stdout as context (activation pointer).
- [ ] Test under Cursor; **merge to `main`.**

### Phase 2 — Codex — `[~]`

Reconciled with the official Codex plugin docs
(<https://developers.openai.com/codex/plugins/build>): Codex reuses Claude's
exact `hooks/hooks.json` (same nested shape, `SessionStart` casing, shell
expansion, seconds timeout) **but only loads the repo as a plugin via its own
required manifest `.codex-plugin/plugin.json`**, which is what declares
`"hooks": "./hooks/hooks.json"` and grants the `CLAUDE_PLUGIN_ROOT` /
`CLAUDE_PLUGIN_DATA` compat aliases (native vars: `PLUGIN_ROOT`/`PLUGIN_DATA`).
So the work is the manifest, not the hook — the hook and script are unchanged.

- [x] Add `.codex-plugin/plugin.json` (mirrors the canonical manifest; declares
      `"skills": "./skills/"` and `"hooks": "./hooks/hooks.json"`). This is the
      necessary+sufficient artifact for the SessionStart hook to fire under Codex.
- [x] Extend `scripts/stamp-version.sh` to sync the version into the Codex
      manifest (jq sets `.version`, preserving the component-path keys — can't
      `cp` the canonical over it like the legacy shim).
- [x] `hooks/hooks.json` unchanged — Codex sets `CLAUDE_PLUGIN_ROOT` (alias) so
      `${CLAUDE_PLUGIN_ROOT}` expands; the Phase 0 `BASH_SOURCE` self-location is
      the backstop if it doesn't (§4.2, §5.2).
- [x] Add Codex's **native** marketplace manifest `.agents/plugins/marketplace.json`
      (rather than leaning on Codex's backward-compat read of
      `.claude-plugin/marketplace.json`). Native schema: structured `source`
      object + `policy` block; the cofounder plugin lives at the repo root so
      `"source": { "source": "local", "path": "./" }`. Keeps the Claude
      `.claude-plugin/marketplace.json` in place (Claude Code still needs it) —
      both coexist. Install path: `codex plugin marketplace add gmautner/marketplace`
      then install `cofounder` from the `/plugins` browser.
- [ ] Confirm the top-level `description` key in `hooks/hooks.json` is ignored by
      Codex (its example omits it). Harmless annotation; verify on first run.
- [ ] Verify on first `marketplace add`: (a) a `local` source `path: "./"` (plugin
      at marketplace root) resolves — docs only show subdir paths like
      `./plugins/<name>`; (b) `policy.authentication: "ON_INSTALL"` is right for a
      no-auth plugin (docs only documented `ON_INSTALL`).
- [ ] Test under Codex; **merge to `main`.**

### Phase 3 — Copilot — `[ ]`

- [ ] Add `.github/hooks/cofounder.json` (§5.6): `version:1`, `sessionStart`,
      `bash`+`powershell`, `timeoutSec`, `cwd:"."`.
- [ ] Resolve the script path (repo-relative, or inject via the in-config `env`).
- [ ] Decide Windows scope (powershell wrapper vs bash-only) (§6).
- [ ] Confirm `sessionStart` stdout-as-context behaviour (§6).
- [ ] Test under Copilot; **merge to `main`.**

### Phase 4 — Gemini — `[ ]`

- [ ] Add the `hooks` block to `.gemini/settings.json` (§5.3): timeout in **ms**.
- [ ] (Re)create `gemini-extension.json` at the root **from this spec, not copied**
      from `feat/gemini-extension`, and have `stamp-version.sh` sync its version.
- [ ] Confirm the Gemini extension install layout and command path against the
      official Gemini docs (§8).
- [ ] Test under Gemini; **merge to `main`.**

### Phase 5 — Hermes — `[ ]`

- [ ] Add a stdin branch to `session-start-sync.sh`: read the project dir from the
      stdin JSON `cwd` when env/`PWD` don't apply (§5.5).
- [ ] Write the `hooks: { on_session_start: [...] }` block into
      `~/.hermes/config.yaml` at install time; absolute script path; seconds.
- [ ] Resolve config-name ambiguity (`config.yaml` vs `cli-config.yaml`) and `~`
      expansion (§6).
- [ ] Decide activation-pointer handling (file-only side-effects vs a
      `pre_llm_call` `{"context": …}` shim) (§6).
- [ ] Test under Hermes; **merge to `main`.**
