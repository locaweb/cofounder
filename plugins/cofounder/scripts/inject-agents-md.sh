#!/usr/bin/env bash
# Injects the cofounder instructions into a project's AGENTS.md between managed markers,
# and a reference to AGENTS.md into CLAUDE.md so Claude (which does not read AGENTS.md
# natively) picks them up via the @import syntax. AGENTS.md is the generic instruction
# file recognized by other harnesses (Gemini, Cursor, etc.).
# Usage: inject-agents-md.sh <project-root> <plugin-root>
# Idempotent — safe to run every session.
set -euo pipefail

PROJECT_ROOT="${1:-.}"
PLUGIN_ROOT="${2:?plugin root required}"

AGENTS_MD="$PROJECT_ROOT/AGENTS.md"
CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
TEMPLATE="$PLUGIN_ROOT/templates/cofounder-instructions.md"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

VERSION=$(jq -r .version "$PLUGIN_JSON")

BEGIN_MARKER="<!-- cofounder:begin COFOUNDER_VERSION: $VERSION -->"
END_MARKER="<!-- cofounder:end -->"

# upsert <file> <block-body>
# Replaces the managed region (between markers) with the given body, creating the
# file or appending the block as needed. Idempotent.
upsert() {
  local file="$1"
  local body="$2"
  local block="$BEGIN_MARKER
$body
$END_MARKER"

  if [ ! -f "$file" ]; then
    # No file — create it with just the managed block
    printf '%s\n' "$block" > "$file"
    echo "CREATED $file with cofounder v$VERSION"
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
    echo "UPDATED cofounder section in $file to v$VERSION"
  else
    # No markers — append the block
    printf '\n%s\n' "$block" >> "$file"
    echo "APPENDED cofounder section to $file (v$VERSION)"
  fi
}

# Full instructions go into AGENTS.md (the generic, cross-harness file).
upsert "$AGENTS_MD" "$(cat "$TEMPLATE")"

# CLAUDE.md only carries an @import reference, since Claude does not read AGENTS.md natively.
upsert "$CLAUDE_MD" "The cofounder operating instructions are maintained in @AGENTS.md — read and follow them."
