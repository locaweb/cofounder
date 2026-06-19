#!/usr/bin/env bash
#
# LLM-as-judge: grade an agent transcript against a rubric. Used for the
# required behaviors a filesystem assertion can't prove (did pre-flight run
# *first*? right persona/language? were tests actually run green?).
#
# Usage: judge.sh <transcript-file> <rubric-text>
# Output: a single line, "PASS" or "FAIL", on stdout (reasoning -> stderr).
#
# The transcript (Claude Code stream-json) can be multi-MB for a big run because
# tool results embed full file contents. We DISTILL it first — the agent's
# narration in order + a tool/test-signal summary — so the judge prompt stays
# small. Runs the judge in a NEUTRAL cwd so it doesn't itself activate the
# cofounder playbook from a project CLAUDE.md.
set -uo pipefail

T="${1:?usage: judge.sh <transcript> <rubric>}"
RUBRIC="${2:?usage: judge.sh <transcript> <rubric>}"

NEUTRAL="$(mktemp -d)"
trap 'rm -rf "$NEUTRAL"' EXIT

distill() {
  local f="$1"
  echo "## Agent narration (in order):"
  grep -o '"text":"[^"]*"' "$f" | sed 's/^"text":"//; s/"$//' | cut -c1-500
  echo
  echo "## Tools used (count):"
  grep -o '"name":"[^"]*"' "$f" | sed 's/^"name":"//; s/"$//' | sort | uniq -c | sort -rn
  echo
  echo "## Test/build result signals:"
  grep -oiE '([0-9]+ (passed|failed)|--- (PASS|FAIL)|^ok [a-z0-9_/.-]+|all tests pass|vitest|tsc -b|go (build|test)|go vet)' "$f" \
    | sort | uniq -c | sort -rn | head -40
}

VIEW="$(distill "$T" | tail -c 200000)"   # hard cap as a safety net

PROMPT="You are a strict, impartial test judge. Evaluate the DISTILLED agent
session transcript below against the rubric. The transcript is a compact digest
(agent narration + tool/test summary), not the raw log. Be skeptical; if a
required behavior is not clearly present, fail it.

RUBRIC:
$RUBRIC

Write a one-paragraph justification, then end with a final line that is EXACTLY
one of:
VERDICT: PASS
VERDICT: FAIL

=== DISTILLED TRANSCRIPT ===
$VIEW"

tbin=""
command -v timeout  >/dev/null 2>&1 && tbin=timeout
[ -z "$tbin" ] && command -v gtimeout >/dev/null 2>&1 && tbin=gtimeout

err="$NEUTRAL/err"
OUT="$( cd "$NEUTRAL" && ${tbin:+$tbin -k 10 180} \
        claude -p "$PROMPT" --permission-mode bypassPermissions 2>"$err" )"

printf '%s\n' "$OUT" >&2                       # reasoning -> stderr for debugging
[ -n "$OUT" ] || { echo "--- judge produced no output; claude stderr: ---" >&2; tail -5 "$err" >&2; }

grep -oE 'VERDICT: (PASS|FAIL)' <<<"$OUT" | tail -1 | awk '{print $2}'
