#!/usr/bin/env bash
#
# Harness adapter: run one headless agent turn and capture the transcript.
# Normalizes the per-harness CLIs so scenarios are written once and (later) run
# across harnesses. Claude is wired now; the others are explicit stubs so the
# matrix shows "not yet wired" instead of silently passing.
#
# Usage:
#   run-agent.sh --harness claude --cwd <dir> --prompt "<text>" --out <file>
#
# Writes the transcript to --out (stream-json JSONL for Claude); stderr to
# <out>.err. Exits with the agent's exit code (3 = harness stub).
set -uo pipefail

HARNESS="" CWD="." OUT="/dev/stdout" PROMPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --cwd)     CWD="$2";     shift 2 ;;
    --out)     OUT="$2";     shift 2 ;;
    --prompt)  PROMPT="$2";  shift 2 ;;
    *) echo "run-agent: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$HARNESS" ]] || { echo "run-agent: --harness required" >&2; exit 2; }
[[ -n "$PROMPT"  ]] || { echo "run-agent: --prompt required"  >&2; exit 2; }

case "$HARNESS" in
  claude)
    ( cd "$CWD" && claude -p "$PROMPT" \
        --output-format stream-json --verbose \
        --permission-mode bypassPermissions ) >"$OUT" 2>"${OUT}.err"
    ;;
  codex)    echo "run-agent: codex not wired yet (codex exec ...)" >&2; exit 3 ;;
  gemini)   echo "run-agent: gemini not wired yet (gemini -p --yolo ...)" >&2; exit 3 ;;
  opencode) echo "run-agent: opencode not wired yet (opencode run ...)" >&2; exit 3 ;;
  *) echo "run-agent: unknown harness '$HARNESS'" >&2; exit 2 ;;
esac
