#!/usr/bin/env bash
#
# Harness adapter: run one headless agent turn and capture the transcript.
# Normalizes the per-harness CLIs so scenarios are written once and (later) run
# across harnesses. Claude is wired now; the others are explicit stubs so the
# matrix shows "not yet wired" instead of silently passing.
#
# Usage:
#   run-agent.sh --harness claude --cwd <dir> --prompt "<text>" --out <file> \
#                [--timeout <seconds>]
#
# Writes the transcript to --out (stream-json JSONL for Claude); stderr to
# <out>.err. Exits with the agent's exit code (3 = harness stub).
set -uo pipefail

HARNESS="" CWD="." OUT="/dev/stdout" PROMPT="" TIMEOUT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="$2"; shift 2 ;;
    --cwd)     CWD="$2";     shift 2 ;;
    --out)     OUT="$2";     shift 2 ;;
    --prompt)  PROMPT="$2";  shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    *) echo "run-agent: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$HARNESS" ]] || { echo "run-agent: --harness required" >&2; exit 2; }
[[ -n "$PROMPT"  ]] || { echo "run-agent: --prompt required"  >&2; exit 2; }

# Run an EXTERNAL command with an optional timeout. 0 = no limit. Prefer a real
# timeout binary (clean process-group kill); fall back to a watchdog otherwise.
run_with_timeout() {
  local secs="$1"; shift
  if [[ "$secs" -le 0 ]]; then "$@"; return $?; fi
  local tbin=""
  command -v timeout  >/dev/null 2>&1 && tbin=timeout
  [[ -z "$tbin" ]] && command -v gtimeout >/dev/null 2>&1 && tbin=gtimeout
  if [[ -n "$tbin" ]]; then "$tbin" -k 10 "$secs" "$@"; return $?; fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 10; kill -KILL "$pid" 2>/dev/null ) &
  local w=$!
  wait "$pid"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return "$rc"
}

case "$HARNESS" in
  claude)
    ( cd "$CWD" && run_with_timeout "$TIMEOUT" \
        claude -p "$PROMPT" --output-format stream-json --verbose \
               --permission-mode bypassPermissions ) >"$OUT" 2>"${OUT}.err"
    ;;
  codex)    echo "run-agent: codex not wired yet (codex exec ...)" >&2; exit 3 ;;
  gemini)   echo "run-agent: gemini not wired yet (gemini -p --yolo ...)" >&2; exit 3 ;;
  opencode)
    # --format json => raw JSON events (text + tool calls, like Claude's
    # stream-json); --dangerously-skip-permissions for headless autonomy.
    # Model: configured default unless COFOUNDER_TEST_OPENCODE_MODEL is set.
    oc=(opencode run "$PROMPT" --format json --dangerously-skip-permissions)
    [ -n "${COFOUNDER_TEST_OPENCODE_MODEL:-}" ] && oc+=(-m "$COFOUNDER_TEST_OPENCODE_MODEL")
    ( cd "$CWD" && run_with_timeout "$TIMEOUT" "${oc[@]}" ) >"$OUT" 2>"${OUT}.err"
    ;;
  *) echo "run-agent: unknown harness '$HARNESS'" >&2; exit 2 ;;
esac
