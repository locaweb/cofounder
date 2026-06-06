# Multi-Harness Hook Compatibility (Claude, Codex, Gemini, Cursor)

Spec for making the cofounder `SessionStart` hook work across Claude Code,
OpenAI Codex, Google Gemini CLI, and Cursor.

Date: 2026-06-06

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
**Gemini CLI**, and **Cursor** as well.

Two independent dimensions drive the work:

1. **JSON syntax compatibility** — does each harness accept the config shape?
2. **Environment variable naming** — does the variable the command relies on
   (`CLAUDE_PLUGIN_ROOT`) exist in each harness?

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

### 3.1 JSON syntax

| Aspect            | Claude               | Codex                 | Gemini                  | Cursor                              |
| ----------------- | -------------------- | --------------------- | ----------------------- | ----------------------------------- |
| Top-level wrapper | `hooks` object       | `hooks` ✅            | `hooks` ✅              | `version: 1` + `hooks` ⚠️ needs `version` |
| Event name        | `SessionStart`       | `SessionStart` ✅     | `SessionStart` ✅       | `sessionStart` ❌ camelCase         |
| Group nesting     | `Event:[{hooks:[…]}]`| same ✅               | same ✅                 | `Event:[{command,…}]` ❌ flat, no inner `hooks[]` |
| Handler keys      | `type,command,timeout`| `+statusMessage` ✅  | `+name,description` ✅  | `command,type,timeout,matcher,failClosed,…` |
| `timeout` unit    | **seconds**          | **seconds** ✅        | **milliseconds** ❌     | **seconds** ✅                      |
| No `matcher` = all | ✅                  | ✅ (omit = all)       | ✅                      | ✅                                  |

### 3.2 Environment variables

The command and the script depend on `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PROJECT_DIR`.

| Var                  | Claude     | Codex                              | Gemini             | Cursor             |
| -------------------- | ---------- | ---------------------------------- | ------------------ | ------------------ |
| `CLAUDE_PLUGIN_ROOT` | ✅ native  | ✅ compat alias (+ `PLUGIN_ROOT`)  | ❌ **not provided** | ❌ **not provided** |
| `CLAUDE_PROJECT_DIR` | ✅         | ❌ (script falls back to `$PWD`)   | ✅ alias           | ✅ alias           |

**The central blocker is `CLAUDE_PLUGIN_ROOT`.** Only Claude and Codex set it
(and Codex only when the hook is loaded *as a plugin* — see §4.2). Under Gemini
and Cursor, `${CLAUDE_PLUGIN_ROOT}` expands to empty, the command becomes
`bash /hooks/session-start-sync.sh` (broken), and the script's
`${CLAUDE_PLUGIN_ROOT:?…}` hard-exits.

### 3.3 Per-harness verdict

| Harness | Verdict |
| ------- | ------- |
| **Codex** | ✅ Works essentially as-is. Identical JSON shape, seconds-based timeout, `CLAUDE_PLUGIN_ROOT` provided for plugin-bundled hooks. |
| **Gemini** | ⚠️ Same shape, but needs timeout in **ms** and a plugin-root that doesn't exist. |
| **Cursor** | ❌ Needs a separate file with a different schema (`version`, lowercase event, flat entries) plus the plugin-root workaround. |

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

---

## 7. Summary

- **Codex**: shares Claude's `hooks/hooks.json` unchanged.
- **Gemini**: add a `hooks` block to `.gemini/settings.json`, timeout in **ms**,
  locate the script via `$GEMINI_PROJECT_DIR`.
- **Cursor**: add `.cursor/hooks.json`, schema `version:1` + `sessionStart` +
  flat entries, locate the script via `$CURSOR_PROJECT_DIR`.
- **Cross-cutting**: make `session-start-sync.sh` self-locating so it no longer
  depends on `CLAUDE_PLUGIN_ROOT`, which only Claude and Codex provide.
