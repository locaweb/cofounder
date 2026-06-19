#!/usr/bin/env bash
#
# Step 4 of the test plan (see ideas/test-plan.md): single-skill headless agent
# runs. Builds the harness adapter + LLM-judge into a real scenario and exercises
# the determinism strategy (outcome assertions + judge + pass-rate over N runs).
#
# Scenario A2 — session start on a neutral greeting. A correctly-activated
# cofounder should: run the pre-flight check first, adopt the persona + the
# user's language, and (no PRD yet) ask what to build.
#
# Local-only: drives headless Claude on THIS machine. Spends tokens. Each run
# bootstraps a throwaway cofounder project (via the real install.sh) with a
# local bare remote so pre-flight syncs cleanly and does not trigger repo-setup
# (no external GitHub side effects).
#
# Usage:   tests/agent/test-agent.sh
#          COFOUNDER_TEST_RUNS=5 tests/agent/test-agent.sh   # pass-rate over N
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

RUN_AGENT="$HERE/run-agent.sh"
JUDGE="$HERE/judge.sh"
INSTALL_SH="$REPO/../skills/cofounder-computer-setup/scripts/install.sh"
HARNESS="${COFOUNDER_TEST_HARNESS:-claude}"
RUNS="${1:-${COFOUNDER_TEST_RUNS:-1}}"   # pass-rate over N runs: `test-agent.sh 5`
PROMPT="oi! tudo bem?"

RUBRIC='This is a "cofounder" agent. On a neutral greeting it MUST:
(1) run the pre-flight check (cofounder-pre-flight-check / preflight.sh) before
    any other substantive work;
(2) adopt the cofounder persona and reply in the user'\''s language — here
    Portuguese, since the user said "oi";
(3) since no product requirements (PRD) exist yet, ASK the user what they want to
    build rather than inventing a project or writing code.
PASS only if all three hold.'

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT

# Bootstrap a throwaway cofounder project with a clean local-remote git state.
setup_project() {
  local p; p="$(mktemp -d "$BASE/proj.XXXXXX")"
  ( cd "$p" && bash "$INSTALL_SH" ) >"$p/.bootstrap.log" 2>&1
  local bare="$p.git"; git init --bare -q -b main "$bare"
  ( cd "$p" && git init -b main -q && git add -A && git commit -qm init \
      && git remote add origin "$bare" && git push -u origin main -q ) >>"$p/.bootstrap.log" 2>&1
  printf '%s' "$p"
}

pass_runs=0
for i in $(seq 1 "$RUNS"); do
  echo "== A2 session-start · run $i/$RUNS ($HARNESS) =="
  proj="$(setup_project)"
  t="$proj/.transcript.jsonl"

  "$RUN_AGENT" --harness "$HARNESS" --cwd "$proj" --prompt "$PROMPT" --out "$t" || true

  before=$FAIL
  expect "[$i] transcript non-empty"        test -s "$t"
  expect "[$i] persona tag [Cofounder]"     file_contains "$t" "[Cofounder]"
  expect "[$i] pre-flight ran"              grep -qiE 'cofounder-pre-flight-check|preflight' "$t"

  verdict="$("$JUDGE" "$t" "$RUBRIC" 2>"$proj/.judge.log" || true)"
  echo "    judge: ${verdict:-<none>}"
  expect "[$i] judge verdict PASS"          test "$verdict" = PASS

  [[ $FAIL -eq $before ]] && pass_runs=$((pass_runs + 1))
done

echo
echo "pass-rate: $pass_runs/$RUNS runs fully green"
summary "agent A2 ($HARNESS)"
