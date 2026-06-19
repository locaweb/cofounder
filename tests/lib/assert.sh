#!/usr/bin/env bash
# Minimal assertion helpers shared by cofounder tests.
# Source this, then use expect/refute. Track PASS/FAIL and exit via summary.

PASS=0
FAIL=0

_pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# expect <description> <command...>   — pass if the command succeeds
expect() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _pass "$d"; else _fail "$d"; fi; }

# refute <description> <command...>   — pass if the command FAILS
refute() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _fail "$d"; else _pass "$d"; fi; }

# file_contains <file> <fixed-string>
file_contains() { grep -qF "$2" "$1"; }

# count_eq <expected-count> <file> <fixed-string>
count_eq() { local n; n=$(grep -cF "$3" "$2" 2>/dev/null || echo 0); [ "$n" -eq "$1" ]; }

# summary <label> — print totals and return non-zero if any assertion failed
summary() { printf '\n%s: %d passed, %d failed\n' "${1:-RESULT}" "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }
