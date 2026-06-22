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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  codex)
    # --json => JSONL events on stdout (msg text + tool/command calls);
    # --dangerously-bypass-approvals-and-sandbox for headless autonomy (mirrors
    # claude's bypassPermissions). Model: configured default unless overridden.
    cx=(codex exec --json --dangerously-bypass-approvals-and-sandbox)
    [ -n "${COFOUNDER_TEST_CODEX_MODEL:-}" ] && cx+=(-m "$COFOUNDER_TEST_CODEX_MODEL")
    cx+=("$PROMPT")
    ( cd "$CWD" && run_with_timeout "$TIMEOUT" "${cx[@]}" ) >"$OUT" 2>"${OUT}.err"
    ;;
  gemini)
    # --output-format stream-json => JSONL events (text + tool calls, like
    # Claude's stream-json); --yolo to auto-approve all tools for headless runs;
    # --skip-trust to run in an untrusted (throwaway) workspace dir.
    # NOTE: the free "Gemini Code Assist for individuals" tier was discontinued
    # (IneligibleTierError); use the `agy` harness (Antigravity successor) instead.
    gm=(gemini -p "$PROMPT" --yolo --skip-trust --output-format stream-json)
    [ -n "${COFOUNDER_TEST_GEMINI_MODEL:-}" ] && gm+=(-m "$COFOUNDER_TEST_GEMINI_MODEL")
    ( cd "$CWD" && run_with_timeout "$TIMEOUT" "${gm[@]}" ) >"$OUT" 2>"${OUT}.err"
    ;;
  agy)
    # agy (Antigravity, gemini's successor) has NO JSON output — `agy -p` prints
    # only the final prose, and its real tool trace (skill loads, shell commands)
    # lives in a per-conversation SQLite "trajectory store". So: capture the
    # prose, find the DB this run produced (new since `before`, else newest),
    # and reconstruct a stream-json transcript the asserts/judge understand.
    # The cofounder skills are read from the project's .agents/skills/ (agy's
    # per-workspace skills dir, populated by install.sh's `universal` target).
    conv="$HOME/.gemini/antigravity-cli/conversations"
    before="$(mktemp)"; after="$(mktemp)"
    ls "$conv"/*.db 2>/dev/null | sort >"$before"
    am=(agy -p "$PROMPT" --dangerously-skip-permissions)
    [ -n "${COFOUNDER_TEST_AGY_MODEL:-}" ] && am+=(--model "$COFOUNDER_TEST_AGY_MODEL")
    ( cd "$CWD" && run_with_timeout "$TIMEOUT" "${am[@]}" ) >"${OUT}.prose" 2>"${OUT}.err"
    rc=$?
    ls "$conv"/*.db 2>/dev/null | sort >"$after"
    db="$(comm -13 "$before" "$after" | tail -1)"
    [ -z "$db" ] && db="$(ls -t "$conv"/*.db 2>/dev/null | head -1)"
    rm -f "$before" "$after"
    python3 "$HERE/agy-transcript.py" "$db" "${OUT}.prose" >"$OUT" 2>>"${OUT}.err"
    exit "$rc"
    ;;
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
