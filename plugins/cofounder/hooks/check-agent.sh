#!/bin/bash

# PreToolUse hook for the Skill tool.
# Blocks cofounder skills when the cofounder agent is not active in the project.
#
# IMPORTANT: This script is fail-closed. If anything goes wrong (missing jq,
# missing env vars, parse errors), cofounder skills are DENIED by default.
# Only non-cofounder skills get a fast allow (exit 0) before any risky code.

DENY_MSG='{"hookSpecificOutput":{"permissionDecision":"deny"},"systemMessage":"BLOCKED — The cofounder agent is not active in this project. Cofounder skills (frontend-design, app-deploy, computer-setup, tech-stack, webapp-testing, etc.) must not be used without the agent'"'"'s coordination. Without it, skills lack orchestrated workflow context and produce incorrect results. Tell the user to run /cofounder:install to activate the cofounder agent, then start a new session for it to take effect."}'

# On any unexpected error, deny the skill
trap 'echo "$DENY_MSG"; exit 0' ERR

INPUT=$(cat)

# Helper: extract a JSON string value by key using grep/sed (no jq needed).
# Usage: json_value "key" <<< "$json"
# Handles simple flat JSON; sufficient for tool_input.skill and .agent fields.
json_value() {
  grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed "s/\"$1\"[[:space:]]*:[[:space:]]*\"//;s/\"$//" | head -1
}

# Extract the skill name from tool input
SKILL=$(echo "$INPUT" | json_value skill) || SKILL=""

# Only care about cofounder:* skills — allow everything else immediately
case "$SKILL" in
  cofounder:*) ;;
  *) exit 0 ;;
esac

# From here on, we're dealing with a cofounder skill.
# Default: deny unless we confirm the agent is active.

if [ -z "${CLAUDE_PROJECT_DIR:-}" ]; then
  echo "$DENY_MSG"
  exit 0
fi

# Check if the cofounder agent is configured in this project
SETTINGS_FILE="$CLAUDE_PROJECT_DIR/.claude/settings.json"
AGENT=""
if [ -f "$SETTINGS_FILE" ]; then
  AGENT=$(json_value agent < "$SETTINGS_FILE" 2>/dev/null) || AGENT=""
fi

if [ "$AGENT" = "cofounder:cofounder" ]; then
  exit 0
fi

# Agent is NOT active — deny the skill
echo "$DENY_MSG"
exit 0
