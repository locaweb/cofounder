#!/usr/bin/env bash
#
# Step 4-adjacent / real-infra (gated): the LIVE repo-setup path.
#
# Step 2's test-scripts.sh covers only repo-init.sh's offline guard branches
# (usage, visibility, auth). This one exercises the real `gh repo create` +
# push against GitHub, then the idempotent re-run, with GUARANTEED teardown
# (the throwaway repo is hard-deleted on exit, even on failure).
#
# Safe by construction:
#   - Owner defaults to the authenticated user (override COFOUNDER_TEST_GH_OWNER).
#   - Repo name is unique per run: cofounder-citest-<epoch>-<rand>.
#   - The repo is PRIVATE and deleted in an EXIT trap.
#
# Prereqs (else the whole suite SKIPs cleanly, exit 0):
#   - gh installed + authenticated.
#   - delete_repo scope on the token, for teardown. Add it with:
#         gh auth refresh -s delete_repo
#     Without it, the test still runs but leaves the repo and FAILS the
#     teardown assertion (so an orphan can't pass silently).
#
# Usage: tests/repo/test-repo-setup-live.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

REPO_INIT="$REPO/../skills/cofounder-repo-setup/scripts/repo-init.sh"
BASH_BIN="$(command -v bash)"

# Deterministic git identity so commits work without host config.
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

# --- gate ------------------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  printf '  SKIP  repo-setup live (gh not installed)\n'; exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
  printf '  SKIP  repo-setup live (gh not authenticated)\n'; exit 0
fi

OWNER="${COFOUNDER_TEST_GH_OWNER:-$(gh api user --jq .login)}"
if [ -z "$OWNER" ]; then
  printf '  SKIP  repo-setup live (could not resolve GitHub owner)\n'; exit 0
fi

# Unique throwaway repo name (this is a shell script — date/RANDOM are fine).
NAME="cofounder-citest-$(date +%s)-$RANDOM"
FULL="$OWNER/$NAME"

HAS_DELETE_SCOPE=0
gh auth status 2>&1 | grep -i 'token scopes' | grep -q 'delete_repo' && HAS_DELETE_SCOPE=1

BASE="$(mktemp -d)"
LOG="$BASE/logs"; mkdir -p "$LOG"

# --- guaranteed teardown ---------------------------------------------------
cleanup() {
  if gh repo view "$FULL" >/dev/null 2>&1; then
    if [ "$HAS_DELETE_SCOPE" = 1 ]; then
      gh repo delete "$FULL" --yes >/dev/null 2>&1 \
        && printf '  teardown: deleted %s\n' "$FULL" \
        || printf '  teardown: FAILED to delete %s (delete it manually)\n' "$FULL"
    else
      printf '  teardown: ORPHAN %s left behind (no delete_repo scope; `gh repo delete %s --yes`)\n' "$FULL" "$FULL"
    fi
  fi
  rm -rf "$BASE"
}
trap cleanup EXIT

echo "== repo-setup live: owner=$OWNER repo=$NAME =="

# --- scenario A: create + push a fresh repo --------------------------------
d="$BASE/proj"; mkdir -p "$d"
(
  cd "$d"
  git init -b main -q
  printf '# %s\n\ncofounder live repo-setup test\n' "$NAME" > README.md
  git add README.md
  git commit -q -m "Initial content"
)
( cd "$d" && "$BASH_BIN" "$REPO_INIT" "$NAME" private ) >"$LOG/create.log" 2>&1
CREATE_RC=$?

expect "create exits 0"                 test "$CREATE_RC" = 0
expect "reports created and pushed"     file_contains "$LOG/create.log" "Repository created and pushed"
expect "origin set locally"             git -C "$d" remote get-url origin
expect "repo exists on GitHub"          gh repo view "$FULL"
expect "repo is private"                test "$(gh repo view "$FULL" --json isPrivate --jq .isPrivate 2>/dev/null)" = true
expect "README pushed to remote"        gh api "repos/$FULL/contents/README.md"
expect "nothing left unpushed"          test -z "$(git -C "$d" rev-list '@{upstream}..HEAD' 2>/dev/null)"

# --- scenario B: idempotent re-run in the same dir (origin already set) -----
( cd "$d" && "$BASH_BIN" "$REPO_INIT" "$NAME" private ) >"$LOG/rerun.log" 2>&1
RERUN_RC=$?

expect "re-run exits 0"                 test "$RERUN_RC" = 0
expect "re-run skips remote creation"   file_contains "$LOG/rerun.log" "Remote 'origin' already set"
refute "re-run created no duplicate"    file_contains "$LOG/rerun.log" "Creating private repository"

# --- teardown assertion (proves cleanup actually works) --------------------
if [ "$HAS_DELETE_SCOPE" = 1 ]; then
  gh repo delete "$FULL" --yes >/dev/null 2>&1
  refute "repo deleted on teardown"     gh repo view "$FULL"
  trap 'rm -rf "$BASE"' EXIT   # repo already gone; just clean the temp dir
else
  _fail "delete_repo scope present (run: gh auth refresh -s delete_repo)"
fi

summary "repo-setup live (gh repo create + push)"
