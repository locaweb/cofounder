#!/usr/bin/env bash
# Injects a static pointer to the cofounder playbook skill into a project's
# AGENTS.md (between managed markers), plus a reference to AGENTS.md into CLAUDE.md
# so Claude (which does not read AGENTS.md natively) picks it up via the @import
# syntax. AGENTS.md is the generic instruction file recognized by other harnesses
# (Codex, Gemini, Cursor, etc.).
#
# The injected content is STATIC and unversioned: the cofounder's actual operating
# instructions live in the `cofounder:playbook` skill, which the plugin update
# mechanism refreshes automatically. The pointer never changes, so it does not need
# to be re-rendered per session — `cofounder:install` writes it once.
#
# Usage: inject-agents-md.sh <project-root> [plugin-root]
# Idempotent — safe to run more than once.
set -euo pipefail

PROJECT_ROOT="${1:-.}"

# Self-locate the plugin root from the script's own on-disk location — a single
# universal mechanism that works under every harness without any harness-provided
# env var. An explicit $2 still overrides it (back-compat for direct callers).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${2:-$(cd "$SCRIPT_DIR/.." && pwd)}"

AGENTS_MD="$PROJECT_ROOT/AGENTS.md"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"

BEGIN_MARKER="<!-- cofounder:begin -->"
END_MARKER="<!-- cofounder:end -->"

# upsert <file> <block-body>
# Replaces the managed region (between markers) with the given body, creating the
# file or appending the block as needed. Idempotent. Matches the begin marker on
# its prefix, so it also rewrites older versioned blocks left by past installs.
upsert() {
  local file="$1"
  local body="$2"
  local block="$BEGIN_MARKER
$body
$END_MARKER"

  if [ ! -f "$file" ]; then
    # No file — create it with just the managed block
    printf '%s\n' "$block" > "$file"
    echo "CREATED $file"
    return
  fi

  if grep -q '<!-- cofounder:begin' "$file"; then
    # Markers exist — replace the managed region
    # Write the new block to a temp file, then use awk to splice it in
    local block_file
    block_file=$(mktemp)
    printf '%s\n' "$block" > "$block_file"
    awk -v blockfile="$block_file" '
      /<!-- cofounder:begin/ { skip=1 }
      skip && /<!-- cofounder:end -->/ {
        while ((getline line < blockfile) > 0) print line
        close(blockfile)
        skip=0
        next
      }
      !skip { print }
    ' "$file" > "$file.tmp"
    rm "$block_file"
    mv "$file.tmp" "$file"
    echo "UPDATED cofounder section in $file"
  else
    # No markers — append the block
    printf '\n%s\n' "$block" >> "$file"
    echo "APPENDED cofounder section to $file"
  fi
}

# AGENTS.md carries a static pointer to the playbook skill (the generic, cross-harness file).
upsert "$AGENTS_MD" "You are operating as a cofounder. Before doing anything else, use the Skill tool to invoke the \`cofounder:playbook\` skill and follow it as your operating instructions for the entire session."

# CLAUDE.md only carries an @import reference, since Claude does not read AGENTS.md natively.
upsert "$CLAUDE_MD" "The cofounder operating instructions are maintained in @AGENTS.md — read and follow them."
