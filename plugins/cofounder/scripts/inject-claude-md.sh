#!/usr/bin/env bash
# Injects the cofounder instructions into a project's CLAUDE.md between managed markers.
# Usage: inject-claude-md.sh <project-root> <plugin-root>
# Idempotent — safe to run every session.
set -euo pipefail

PROJECT_ROOT="${1:-.}"
PLUGIN_ROOT="${2:?plugin root required}"

CLAUDE_MD="$PROJECT_ROOT/CLAUDE.md"
TEMPLATE="$PLUGIN_ROOT/templates/cofounder-instructions.md"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found at $TEMPLATE" >&2
  exit 1
fi

VERSION=$(jq -r .version "$PLUGIN_JSON")
CONTENT=$(cat "$TEMPLATE")

BEGIN_MARKER="<!-- cofounder:begin COFOUNDER_VERSION: $VERSION -->"
END_MARKER="<!-- cofounder:end -->"

BLOCK="$BEGIN_MARKER
$CONTENT
$END_MARKER"

if [ ! -f "$CLAUDE_MD" ]; then
  # No CLAUDE.md — create it with just the managed block
  printf '%s\n' "$BLOCK" > "$CLAUDE_MD"
  echo "CREATED $CLAUDE_MD with cofounder v$VERSION"
  exit 0
fi

if grep -q '<!-- cofounder:begin' "$CLAUDE_MD"; then
  # Markers exist — replace the managed region
  # Write the new block to a temp file, then use awk to splice it in
  BLOCK_FILE=$(mktemp)
  printf '%s\n' "$BLOCK" > "$BLOCK_FILE"
  awk -v blockfile="$BLOCK_FILE" '
    /<!-- cofounder:begin/ { skip=1 }
    skip && /<!-- cofounder:end -->/ {
      while ((getline line < blockfile) > 0) print line
      close(blockfile)
      skip=0
      next
    }
    !skip { print }
  ' "$CLAUDE_MD" > "$CLAUDE_MD.tmp"
  rm "$BLOCK_FILE"
  mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
  echo "UPDATED cofounder section in $CLAUDE_MD to v$VERSION"
else
  # No markers — append the block
  printf '\n%s\n' "$BLOCK" >> "$CLAUDE_MD"
  echo "APPENDED cofounder section to $CLAUDE_MD (v$VERSION)"
fi
