#!/usr/bin/env bash
set -euo pipefail

PLUGIN_JSON="$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json"

if [ -f "$PLUGIN_JSON" ]; then
  CONTENT=$(cat "$PLUGIN_JSON")
else
  CONTENT="plugin.json not found"
fi

cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Loaded cofounder plugin.json: ${CONTENT}"
  }
}
EOF

exit 0
