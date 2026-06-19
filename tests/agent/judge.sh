#!/usr/bin/env bash
#
# LLM-as-judge: grade an agent transcript against a rubric. Used for the
# required behaviors a filesystem assertion can't prove (did pre-flight run
# *first*? right persona/language? asked instead of assuming?).
#
# Usage: judge.sh <transcript-file> <rubric-text>
# Output: a single line, "PASS" or "FAIL", on stdout (reasoning goes to stderr).
#
# Runs the judge agent in a NEUTRAL temp cwd so it doesn't itself activate the
# cofounder playbook from a project CLAUDE.md.
set -uo pipefail

T="${1:?usage: judge.sh <transcript> <rubric>}"
RUBRIC="${2:?usage: judge.sh <transcript> <rubric>}"

NEUTRAL="$(mktemp -d)"
trap 'rm -rf "$NEUTRAL"' EXIT

PROMPT="You are a strict, impartial test judge. Evaluate the agent session
transcript below against the rubric. Be skeptical; if a required behavior is not
clearly present, fail it.

RUBRIC:
$RUBRIC

Write a one-paragraph justification, then end with a final line that is EXACTLY
one of:
VERDICT: PASS
VERDICT: FAIL

=== TRANSCRIPT (Claude Code stream-json) ===
$(cat "$T")"

OUT="$( cd "$NEUTRAL" && claude -p "$PROMPT" --permission-mode bypassPermissions 2>/dev/null )"
printf '%s\n' "$OUT" >&2   # reasoning -> stderr for debugging

# Extract the final verdict token.
grep -oE 'VERDICT: (PASS|FAIL)' <<<"$OUT" | tail -1 | awk '{print $2}'
