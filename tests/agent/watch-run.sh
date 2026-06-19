#!/usr/bin/env bash
#
# Per-minute progress for a long-running agent test (e.g. the e2e scaffold).
# Prints one snapshot line per interval and exits when the runner finishes.
# Designed to be passed to Claude Code's Monitor tool, but also runs standalone.
#
# Usage:
#   tests/agent/watch-run.sh <runner-output-file> [project-dir] [interval-seconds]
#
#   <runner-output-file>  the file capturing test-agent.sh's stdout (the run is
#                         done when it contains "pass-rate:"). With Monitor this
#                         is the background task's output file; standalone, point
#                         it at a file you redirected the runner into.
#   [project-dir]         the throwaway project to watch. Omit to auto-discover
#                         the newest cofoundertest.* dir.
#   [interval-seconds]    snapshot cadence (default 60).
#
# Pattern (reproducible from a clean session):
#   1. launch the run in the background (Bash run_in_background, or `&`)
#   2. Monitor this script with the run's output file as $1
#
# Notes:
#   - Portable on macOS: no `xargs -r` (BSD xargs lacks it), no GNU-only flags.
#   - Read-only (find/wc/grep/podman ps/stat), so it won't disturb the run.
set -uo pipefail

OUT="${1:?usage: watch-run.sh <runner-output-file> [project-dir] [interval]}"
PROJ="${2:-}"
INT="${3:-60}"

# GNU stat (coreutils) uses -c %Y; BSD/macOS stat uses -f %m. Try GNU first
# because `stat -f` on GNU silently succeeds with the wrong output.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Newest cofoundertest.* project dir (skipping the bare .git remote).
find_proj() {
  local best="" bestt=0 d t
  while IFS= read -r d; do
    case "$d" in *.git) continue ;; esac
    t=$(mtime "$d"); [ -z "$t" ] && continue
    if [ "$t" -gt "$bestt" ]; then bestt="$t"; best="$d"; fi
    # macOS puts mktemp dirs deep under /var/folders (~depth 5); don't rely on
    # TMPDIR being exported in the monitor's shell. maxdepth 8 covers both.
  done < <(find /var/folders /tmp -maxdepth 8 -type d -name 'cofoundertest.*' 2>/dev/null)
  printf '%s' "$best"
}

while true; do
  p="$PROJ"; [ -z "$p" ] && p="$(find_proj)"
  if [ -n "$p" ] && [ -f "$p/.transcript.jsonl" ]; then
    ev=$(wc -l < "$p/.transcript.jsonl" 2>/dev/null | tr -d ' ')
    last=$(grep -o '"text":"[^"]*"' "$p/.transcript.jsonl" 2>/dev/null | tail -1 | cut -c1-130)
    be=$([ -d "$p/backend" ]  && echo backend  || echo no-backend)
    fe=$([ -d "$p/frontend" ] && echo frontend || echo no-frontend)
    db=$(podman ps --format '{{.Status}}' --filter name=cofoundertest 2>/dev/null | head -1)
    printf '%s | events=%s | %s %s | db:%s | %s\n' "$(date +%H:%M:%S)" "${ev:-0}" "$be" "$fe" "${db:-down}" "${last:-...}"
  else
    printf '%s | (bootstrap / no transcript yet)\n' "$(date +%H:%M:%S)"
  fi
  if grep -q 'pass-rate:' "$OUT" 2>/dev/null; then printf 'DONE — runner finished\n'; break; fi
  sleep "$INT"
done
