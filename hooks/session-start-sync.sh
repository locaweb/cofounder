#!/usr/bin/env bash
# SessionStart hook for the cofounder plugin.
#
# Purpose: make activation robust across plugin updates — especially for projects
# installed by an older version that activated via the `.claude/settings.json`
# "agent" key (now removed). Such projects have no CLAUDE.md/AGENTS.md to bootstrap
# the new injection model, and a dangling "agent": "cofounder:cofounder" reference.
#
# On every session start, for cofounder projects only, this hook:
#   1. Syncs AGENTS.md + the @AGENTS.md reference in CLAUDE.md (idempotent).
#   2. Removes the obsolete "agent" key from .claude/settings.json (legacy migration).
#   3. Emits a short pointer so the current session activates even if CLAUDE.md was
#      not present when the session's project context was first loaded.
#
# Self-gating: does nothing unless the project already looks like a cofounder
# project, so it is safe even when the plugin is enabled globally.
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

is_cofounder_project() {
  # Legacy activation: settings.json "agent" referencing the cofounder agent
  if [ -f "$SETTINGS" ] && grep -q '"agent"[[:space:]]*:[[:space:]]*"cofounder' "$SETTINGS" 2>/dev/null; then
    return 0
  fi
  # New activation: managed markers already present in either instruction file
  for f in "$AGENTS_MD" "$CLAUDE_MD"; do
    [ -f "$f" ] && grep -q '<!-- cofounder:begin' "$f" 2>/dev/null && return 0
  done
  return 1
}

# Not a cofounder project — stay completely silent and do nothing.
is_cofounder_project || exit 0

# 1. Sync AGENTS.md + CLAUDE.md reference (idempotent). Never block the session.
bash "$PLUGIN_ROOT/scripts/inject-agents-md.sh" "$PROJECT_DIR" "$PLUGIN_ROOT" >/dev/null 2>&1 || true

# 2. Migrate legacy installs: drop the obsolete "agent" key from settings.json.
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1 && jq -e 'has("agent")' "$SETTINGS" >/dev/null 2>&1; then
  tmp=$(mktemp)
  if jq 'del(.agent)' "$SETTINGS" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS"
  else
    rm -f "$tmp"
  fi
fi

# 3. Activate for the current session. stdout from a SessionStart hook is added to
#    the session context, so a one-line pointer guarantees activation even on the
#    very session that just bootstrapped the files above.
echo "[Cofounder] This is a cofounder project. Read AGENTS.md in the project root and follow it as your operating instructions for this session."

exit 0
