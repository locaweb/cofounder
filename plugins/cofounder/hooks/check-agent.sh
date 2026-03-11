#!/bin/bash

# PreToolUse hook for the Skill tool.
# Blocks cofounder skills when the cofounder agent is not active.
# Fail-closed: if anything is unexpected, cofounder skills are denied.

INPUT=$(cat)

# Check if this is a cofounder skill (quick grep, no jq needed)
echo "$INPUT" | grep -q '"cofounder:' || exit 0

# It is a cofounder skill. Check if the agent is active.
SETTINGS="${CLAUDE_PROJECT_DIR:-.}/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q '"cofounder:cofounder"' "$SETTINGS" 2>/dev/null; then
  exit 0
fi

# Agent is NOT active — deny
printf '{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"BLOCKED: The cofounder agent is not active in this project. Run /cofounder:install to activate it, then start a new session."}\n'
exit 0
