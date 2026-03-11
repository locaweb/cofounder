#!/bin/bash

# PreToolUse hook for the Skill tool.
# Blocks cofounder skills when the cofounder agent is not active.
#
# Exit 0 = allow, Exit 2 = block (stderr fed back to Claude).

INPUT=$(cat)

# Allow everything that isn't a cofounder skill
echo "$INPUT" | grep -q '"cofounder:' || exit 0

# Always allow cofounder:install — it's the bootstrap command
echo "$INPUT" | grep -q '"cofounder:install"' && exit 0

# It is a cofounder skill. Check if the agent is active.
SETTINGS="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q '"cofounder:cofounder"' "$SETTINGS" 2>/dev/null; then
  exit 0
fi

# Agent is NOT active — block the skill
echo "BLOCKED: The cofounder agent is not active in this project. Cofounder skills require the agent for orchestration. Tell the user to type the slash command /cofounder:install (it is a command, not a skill — do NOT invoke it via the Skill tool) to activate it, then start a new session." >&2
exit 2
