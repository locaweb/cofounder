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

# Is the cofounder agent actually active in this session?
# When settings.json "agent" field is in effect, the hook input includes
# "agent_type". Checking this instead of settings.json avoids a loophole
# where /cofounder:install writes the file but the agent isn't active
# until the next session.
echo "$INPUT" | grep -q '"agent_type".*cofounder' && exit 0

# Agent is NOT active — block the skill
echo "BLOCKED: The cofounder agent is not active in this project. Cofounder skills require the agent for orchestration. Tell the user to type the slash command /cofounder:install (it is a command, not a skill — do NOT invoke it via the Skill tool) to activate it, then start a new session." >&2
exit 2
