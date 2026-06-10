#!/usr/bin/env bash
# SessionStart hook for the cofounder plugin.
#
# The cofounder's operating instructions live in the `cofounder:playbook` skill
# (auto-refreshed by the plugin update mechanism), and the project's AGENTS.md
# carries a static, unversioned pointer to it that `cofounder:install` writes once.
# So there is nothing to re-render per session for a normally-installed project —
# Claude loads it via the @AGENTS.md import in CLAUDE.md, Codex reads AGENTS.md
# natively, and this hook stays completely silent.
#
# Its ONLY remaining job is a one-time rescue of legacy projects: those installed
# before the injection model, which activated via a `.claude/settings.json`
# "agent": "cofounder:cofounder" key (now removed) and have no AGENTS.md/CLAUDE.md
# markers. For exactly those, this hook bootstraps the instruction files, drops the
# obsolete agent key, and emits a one-time activation pointer for the current
# session. Once migrated (markers present), it does nothing ever again.
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

# Already migrated (new injection model): managed markers present in either
# instruction file. Static content + native loading — nothing to do, stay silent.
for f in "$AGENTS_MD" "$CLAUDE_MD"; do
  [ -f "$f" ] && grep -q '<!-- cofounder:begin' "$f" 2>/dev/null && exit 0
done

# Not migrated and no legacy agent key → not a cofounder project. Stay silent.
if ! { [ -f "$SETTINGS" ] && grep -q '"agent"[[:space:]]*:[[:space:]]*"cofounder' "$SETTINGS" 2>/dev/null; }; then
  exit 0
fi

# Legacy, unmigrated project: perform the one-time rescue.

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
