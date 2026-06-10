#!/usr/bin/env bash
# SessionStart hook for the cofounder plugin.
#
# The cofounder's operating instructions live in the `cofounder:playbook` skill
# (auto-refreshed by the plugin update mechanism), and the project's AGENTS.md
# carries a static, unversioned pointer to it that `cofounder:install` writes once.
# So for a project already on that pointer there is nothing to do — Claude loads it
# via the @AGENTS.md import in CLAUDE.md, Codex reads AGENTS.md natively, and this
# hook stays completely silent.
#
# Its job is to migrate projects from earlier install generations onto the pointer,
# each migration being one-time (afterwards the project matches the silent case):
#
#   Stage 1 — Legacy agent-key: installed before the injection model, activated via
#             a `.claude/settings.json` "agent": "cofounder:cofounder" key (now gone)
#             and with no AGENTS.md/CLAUDE.md markers. Rescue = inject the files,
#             drop the obsolete key, and emit a one-time activation pointer for this
#             session (its CLAUDE.md did not exist when the harness loaded context).
#
#   Stage 2 — Fat versioned block: AGENTS.md/CLAUDE.md carry the old managed block
#             whose begin marker is stamped `COFOUNDER_VERSION: x.y.z` and which
#             inlined the full instructions. Convert = re-inject, replacing the fat
#             block with the static pointer. No echo: CLAUDE.md already exists, so
#             this session already loaded the (complete, if stale) inline copy.
#
#   Stage 3 — Static pointer: bare `<!-- cofounder:begin -->` marker. Nothing to do.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Resolve the plugin root from the script's own on-disk location. This is a single
# universal mechanism that works identically under every harness (Claude, Codex,
# Gemini, Cursor, Hermes, Copilot) and depends on NO harness-provided env var — not
# even Claude's own CLAUDE_PLUGIN_ROOT, nor Codex's compat aliases.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SETTINGS="$PROJECT_DIR/.claude/settings.json"
AGENTS_MD="$PROJECT_DIR/AGENTS.md"
CLAUDE_MD="$PROJECT_DIR/CLAUDE.md"

# A versioned begin marker (`COFOUNDER_VERSION: ...`) means a Stage-2 fat block.
has_versioned_marker() {
  for f in "$AGENTS_MD" "$CLAUDE_MD"; do
    [ -f "$f" ] && grep -q '<!-- cofounder:begin COFOUNDER_VERSION' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Any begin marker at all (bare pointer or versioned).
has_any_marker() {
  for f in "$AGENTS_MD" "$CLAUDE_MD"; do
    [ -f "$f" ] && grep -q '<!-- cofounder:begin' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Stage 2 → Stage 3: replace the fat versioned block with the static pointer. The
# inject is idempotent and matches the begin-marker prefix, so it rewrites the old
# block in place. No stdout (this session already has the inline instructions).
if has_versioned_marker; then
  bash "$PLUGIN_ROOT/scripts/inject-agents-md.sh" "$PROJECT_DIR" "$PLUGIN_ROOT" >/dev/null 2>&1 || true
  exit 0
fi

# Stage 3: already on the static pointer — nothing to do, stay silent.
if has_any_marker; then
  exit 0
fi

# No markers. Either a Stage-1 legacy project (has the agent key) or not a cofounder
# project at all. If there is no legacy agent key, stay silent.
if ! { [ -f "$SETTINGS" ] && grep -q '"agent"[[:space:]]*:[[:space:]]*"cofounder' "$SETTINGS" 2>/dev/null; }; then
  exit 0
fi

# Stage 1 legacy rescue.

# 1. Bootstrap AGENTS.md + the @AGENTS.md reference in CLAUDE.md. Never block the session.
bash "$PLUGIN_ROOT/scripts/inject-agents-md.sh" "$PROJECT_DIR" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

# 2. Drop the obsolete "agent" key from settings.json.
if command -v jq >/dev/null 2>&1 && jq -e 'has("agent")' "$SETTINGS" >/dev/null 2>&1; then
  tmp=$(mktemp)
  if jq 'del(.agent)' "$SETTINGS" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS"
  else
    rm -f "$tmp"
  fi
fi

# 3. Activate for the current session. stdout from a SessionStart hook is injected
#    into the session context, guaranteeing activation even on this very session
#    that just bootstrapped the files above. Emit the structured JSON envelope:
#    Claude Code and Codex both support `hookSpecificOutput.additionalContext` for
#    SessionStart, and Codex *requires* JSON here — it rejects bare plain-text
#    stdout as "invalid session start JSON output". This line is the hook's entire
#    stdout (steps 1 and 2 above redirect theirs away), so it stays valid JSON.
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"[Cofounder] This is a cofounder project. Read AGENTS.md in the project root and follow it as your operating instructions for this session."}}
JSON

exit 0
