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

# mkrepo <dir> — git repo with a local bare remote, one commit pushed, ready to sync.
mkrepo() {
  local d="$1" bare="$1.git"
  git init --bare -q -b main "$bare"
  mkdir -p "$d"
  ( cd "$d" && git init -b main -q && git commit --allow-empty -m init -q \
     && git remote add origin "$bare" && git push -u origin main -q )
}

echo "== preflight: sensitive file guard — untracked secrets block the sync =="
d="$BASE/s9"; mkrepo "$d"
mkdir -p "$d/config" "$d/tls"
echo "SECRET=abc" >"$d/.env"
echo "SECRET=abc" >"$d/prod.env"            # <name>.env convention
echo "SECRET=abc" >"$d/config/staging.env"  # <name>.env in a subdirectory
echo "SECRET=abc" >"$d/.env.local"          # .env.<suffix>
touch "$d/server.key" "$d/tls/private.key" "$d/app.secret" "$d/id_rsa"
pf s9 "$d" "$FAKEHOME" "$PATH"
expect "exit 1"                       test "$(rc s9)" = 1
expect "SENSITIVE_FILES_DETECTED"     file_contains "$LOG/s9.log" "SENSITIVE_FILES_DETECTED"
for f in .env prod.env config/staging.env .env.local server.key tls/private.key app.secret id_rsa; do
  expect "lists $f"                   file_contains "$LOG/s9.log" "$f"
done
expect "nothing was committed"        test -z "$(git -C "$d" log --oneline -1 --grep='Auto-sync')"

echo "== preflight: sensitive file guard — templates and lookalikes do not block =="
d="$BASE/s10"; mkrepo "$d"
mkdir -p "$d/src"
echo "SECRET=changeme" >"$d/.env.example"
echo "SECRET=changeme" >"$d/.env.sample"
echo "SECRET=changeme" >"$d/prod.env.template"
echo "export const x = 1" >"$d/src/environment.ts"   # contains "env", must not match
touch "$d/foo.environment" "$d/keyboard.md" "$d/monkey.txt"
pf s10 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s10.log" "PREFLIGHT_PASSED"
refute "no false positive"            file_contains "$LOG/s10.log" "SENSITIVE_FILES_DETECTED"
expect "committed normally"           file_contains "$LOG/s10.log" "SYNC: Committing local changes..."

echo "== preflight: sensitive file guard — staged secret blocks with restore advice =="
d="$BASE/s11"; mkrepo "$d"
echo "SECRET=abc" >"$d/.env"
git -C "$d" add -f .env
pf s11 "$d" "$FAKEHOME" "$PATH"
expect "exit 1"                       test "$(rc s11)" = 1
expect "SENSITIVE_FILES_DETECTED"     file_contains "$LOG/s11.log" "SENSITIVE_FILES_DETECTED"
expect "suggests restore --staged"    file_contains "$LOG/s11.log" "git restore --staged"

echo "== preflight: sensitive file guard — tracked+modified secret suggests git rm --cached =="
d="$BASE/s12"; mkrepo "$d"
echo "SECRET=abc" >"$d/.env"
( cd "$d" && git add -f .env && git commit -qm "add env" && git push -q )
echo "SECRET=changed" >"$d/.env"     # tracked and modified — the deadlock case
pf s12 "$d" "$FAKEHOME" "$PATH"
expect "exit 1"                       test "$(rc s12)" = 1
expect "SENSITIVE_FILES_DETECTED"     file_contains "$LOG/s12.log" "SENSITIVE_FILES_DETECTED"
expect "suggests git rm --cached"     file_contains "$LOG/s12.log" "git rm --cached"

echo "== preflight: sensitive file guard — deleting a tracked secret does NOT block =="
d="$BASE/s13"; mkrepo "$d"
echo "SECRET=abc" >"$d/.env"
( cd "$d" && git add -f .env && git commit -qm "add env" && git push -q )
rm "$d/.env"                          # the correct cleanup must not deadlock the session
pf s13 "$d" "$FAKEHOME" "$PATH"
expect "PREFLIGHT_PASSED"             file_contains "$LOG/s13.log" "PREFLIGHT_PASSED"
refute "not blocked on deletion"      file_contains "$LOG/s13.log" "SENSITIVE_FILES_DETECTED"
expect "deletion was committed"       test -z "$(git -C "$d" ls-files .env)"

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
