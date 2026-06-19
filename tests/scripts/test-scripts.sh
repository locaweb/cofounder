#!/usr/bin/env bash
#
# Step 2 of the test plan (see ideas/test-plan.md): deterministic, offline tests
# for the bundled shell scripts, driven in throwaway temp dirs on the host.
# No container, no network, no agent.
#
#   - preflight.sh : every branch (home-dir guard, existing-content guard,
#                    exempt-content, git-sync with a local bare remote, tool
#                    detection, remote detection).
#   - repo-init.sh : the offline guard branches (usage, visibility, auth).
#                    The real `gh repo create` path is real-infra → covered
#                    later against a dedicated test org, not here.
#
# Usage: tests/scripts/test-scripts.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

PREFLIGHT="$REPO/../skills/cofounder-pre-flight-check/scripts/preflight.sh"
REPO_INIT="$REPO/../skills/cofounder-repo-setup/scripts/repo-init.sh"
BASH_BIN="$(command -v bash)"

# Deterministic git identity so commits work without host config.
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
FAKEHOME="$BASE/home"; mkdir -p "$FAKEHOME"
LOG="$BASE/logs"; mkdir -p "$LOG"

# pf <name> <cwd> <home> <path> — run preflight.sh with controlled cwd/HOME/PATH.
pf() {
  ( cd "$2" && HOME="$3" PATH="$4" "$BASH_BIN" "$PREFLIGHT" ) >"$LOG/$1.log" 2>&1
  printf '%s' "$?" >"$LOG/$1.rc"
}
rc() { cat "$LOG/$1.rc"; }

echo "== preflight: home-dir guard =="
d="$BASE/s1"; mkdir -p "$d"
d_phys="$(cd "$d" && pwd -P)"     # preflight compares pwd -P, so resolve symlinks (/var → /private/var)
pf s1 "$d" "$d_phys" "$PATH"   # HOME == cwd (physical)
expect "exit 1"                 test "$(rc s1)" = 1
expect "PREFLIGHT_FAILED"       file_contains "$LOG/s1.log" "PREFLIGHT_FAILED"
expect "IN_HOME_DIR reported"   file_contains "$LOG/s1.log" "IN_HOME_DIR"

echo "== preflight: existing content, no git =="
d="$BASE/s2"; mkdir -p "$d"; echo x >"$d/file.txt"
pf s2 "$d" "$FAKEHOME" "$PATH"
expect "exit 1"                       test "$(rc s2)" = 1
expect "EXISTING_CONTENT_NO_GIT"      file_contains "$LOG/s2.log" "EXISTING_CONTENT_NO_GIT"

echo "== preflight: exempt content (CLAUDE.md/AGENTS.md/.claude), no git =="
d="$BASE/s3"; mkdir -p "$d/.claude"; echo x >"$d/CLAUDE.md"; echo y >"$d/AGENTS.md"
pf s3 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s3.log" "PREFLIGHT_PASSED"
refute "no EXISTING_CONTENT error"    file_contains "$LOG/s3.log" "EXISTING_CONTENT_NO_GIT"
expect "NEEDS_REPO_SETUP (no git)"    file_contains "$LOG/s3.log" "NEEDS_REPO_SETUP: no git repository"

echo "== preflight: freshly-installed project, no git (real install.sh output set) =="
# Mirrors exactly what install.sh writes before `git init` (.agents, .claude,
# .hermes, AGENTS.md, CLAUDE.md, .gitignore, skills-lock.json). Regression for the
# OpenCode report where these tripped EXISTING_CONTENT_NO_GIT.
d="$BASE/s3b"; mkdir -p "$d/.agents/skills" "$d/.claude/skills" "$d/.hermes/skills"
echo '{}' >"$d/.claude/settings.json"; echo y >"$d/AGENTS.md"; echo z >"$d/CLAUDE.md"
printf '.claude/skills/\n.agents/skills/\n.hermes/skills/\nskills-lock.json\n' >"$d/.gitignore"
echo '{}' >"$d/skills-lock.json"
pf s3b "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s3b.log" "PREFLIGHT_PASSED"
refute "no EXISTING_CONTENT error"    file_contains "$LOG/s3b.log" "EXISTING_CONTENT_NO_GIT"
expect "NEEDS_REPO_SETUP (no git)"    file_contains "$LOG/s3b.log" "NEEDS_REPO_SETUP: no git repository"

echo "== preflight: empty dir, no git =="
d="$BASE/s4"; mkdir -p "$d"
pf s4 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s4.log" "PREFLIGHT_PASSED"
expect "NEEDS_REPO_SETUP (no git)"    file_contains "$LOG/s4.log" "NEEDS_REPO_SETUP: no git repository"

echo "== preflight: git repo, no remote (sync skipped) =="
d="$BASE/s5"; mkdir -p "$d"; ( cd "$d" && git init -b main -q && git commit --allow-empty -m init -q )
pf s5 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"                       file_contains "$LOG/s5.log" "PREFLIGHT_PASSED"
expect "NEEDS_REPO_SETUP (repo, no remote)"     file_contains "$LOG/s5.log" "NEEDS_REPO_SETUP: git repo exists but no remote configured"
refute "no sync attempted"                      file_contains "$LOG/s5.log" "SYNC:"

echo "== preflight: git repo with remote, clean =="
bare="$BASE/s6.git"; git init --bare -q -b main "$bare"
d="$BASE/s6"; mkdir -p "$d"
( cd "$d" && git init -b main -q && git commit --allow-empty -m init -q \
   && git remote add origin "$bare" && git push -u origin main -q )
pf s6 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s6.log" "PREFLIGHT_PASSED"
expect "reports up to date"           file_contains "$LOG/s6.log" "Repository is up to date."

echo "== preflight: git repo with remote, dirty (auto-commit + push) =="
bare="$BASE/s7.git"; git init --bare -q -b main "$bare"
d="$BASE/s7"; mkdir -p "$d"
( cd "$d" && git init -b main -q && git commit --allow-empty -m init -q \
   && git remote add origin "$bare" && git push -u origin main -q )
echo "change" >"$d/new.txt"
pf s7 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s7.log" "PREFLIGHT_PASSED"
expect "committed local changes"      file_contains "$LOG/s7.log" "SYNC: Committing local changes..."
expect "nothing left unpushed"        test -z "$(git -C "$d" rev-list '@{upstream}..HEAD' 2>/dev/null)"

echo "== preflight: dev tools missing =="
d="$BASE/s8"; mkdir -p "$d"
pf s8 "$d" "$FAKEHOME" "/nonexistent"   # hide podman/mise/gh
expect "NEEDS_COMPUTER_SETUP"         file_contains "$LOG/s8.log" "NEEDS_COMPUTER_SETUP: missing podman mise gh"
expect "still PREFLIGHT_PASSED"       file_contains "$LOG/s8.log" "PREFLIGHT_PASSED"

echo "== repo-init: missing repo name =="
( cd "$BASE" && "$BASH_BIN" "$REPO_INIT" ) >"$LOG/r1.log" 2>&1; printf '%s' "$?" >"$LOG/r1.rc"
expect "exit nonzero"                 test "$(rc r1)" != 0
expect "prints usage"                 file_contains "$LOG/r1.log" "Usage"

echo "== repo-init: invalid visibility =="
( cd "$BASE" && "$BASH_BIN" "$REPO_INIT" myrepo bogus ) >"$LOG/r2.log" 2>&1; printf '%s' "$?" >"$LOG/r2.rc"
expect "exit 1"                       test "$(rc r2)" = 1
expect "rejects visibility"           file_contains "$LOG/r2.log" "visibility must be"

echo "== repo-init: not authenticated =="
if command -v gh >/dev/null 2>&1; then
  ( cd "$BASE" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN \
      GH_CONFIG_DIR="$BASE/empty-gh" HOME="$FAKEHOME" \
      "$BASH_BIN" "$REPO_INIT" myrepo private ) >"$LOG/r3.log" 2>&1; printf '%s' "$?" >"$LOG/r3.rc"
  expect "exit 1"                     test "$(rc r3)" = 1
  expect "reports not authenticated"  file_contains "$LOG/r3.log" "Not authenticated"
else
  printf '  SKIP  repo-init not-authenticated (gh not installed)\n'
fi

summary "scripts (preflight + repo-init)"
