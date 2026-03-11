#!/bin/bash
set -euo pipefail

# PreToolUse hook for the Skill tool.
# Blocks cofounder skills when the cofounder agent is not active in the project.

INPUT=$(cat)

# Extract the skill name from tool input
SKILL=$(echo "$INPUT" | jq -r '.tool_input.skill // empty')

# Only care about cofounder:* skills
case "$SKILL" in
  cofounder:*) ;;
  *) exit 0 ;;
esac

# Check if the cofounder agent is configured in this project
SETTINGS_FILE="$CLAUDE_PROJECT_DIR/.claude/settings.json"
AGENT=""
if [ -f "$SETTINGS_FILE" ]; then
  AGENT=$(jq -r '.agent // empty' "$SETTINGS_FILE" 2>/dev/null || true)
fi

if [ "$AGENT" = "cofounder:cofounder" ]; then
  exit 0
fi

# Agent is NOT active — deny the skill
cat <<'EOF'
{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"BLOCKED — The cofounder agent is not active in this project. Cofounder skills (frontend-design, app-deploy, computer-setup, tech-stack, webapp-testing, etc.) must not be used without the agent's coordination. Without it, skills lack orchestrated workflow context and produce incorrect results. Tell the user to run /cofounder:install to activate the cofounder agent, then start a new session for it to take effect."}
EOF
exit 0
