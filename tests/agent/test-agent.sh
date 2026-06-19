#!/usr/bin/env bash
#
# Step 4 of the test plan (see ideas/test-plan.md): headless agent runs built on
# the run-agent.sh adapter + judge.sh, exercising the determinism strategy
# (outcome assertions + LLM judge + pass-rate over N runs).
#
# Scenarios:
#   a2  (default) — session start on a neutral greeting: pre-flight first,
#                   persona + language, asks what to build (no PRD invented).
#   e2e           — scaffold a full app from a fixed PRD (A4) and have its tests
#                   pass (A5). Deterministic: backend/+frontend/ exist, `go build`
#                   compiles, `tsc -b` passes. Judge: implemented per PRD, ran Go
#                   + frontend tests green, followed stack conventions, no deploy.
#
# Local-only: drives headless Claude on THIS machine. Spends tokens. Each run
# bootstraps a throwaway cofounder project (via the real install.sh) with a local
# bare remote so pre-flight syncs cleanly and does not trigger repo-setup (no
# GitHub side effects). The e2e scenario also starts a podman DB container and is
# cleaned up after each run.
#
# Usage:
#   tests/agent/test-agent.sh              # a2, 1 run
#   tests/agent/test-agent.sh a2 5         # a2, pass-rate over 5 runs
#   tests/agent/test-agent.sh e2e          # e2e, 1 run
#   tests/agent/test-agent.sh e2e 3        # e2e, pass-rate over 3 runs
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/lib/assert.sh"

RUN_AGENT="$HERE/run-agent.sh"
JUDGE="$HERE/judge.sh"
INSTALL_SH="$REPO/../skills/cofounder-computer-setup/scripts/install.sh"
HARNESS="${COFOUNDER_TEST_HARNESS:-claude}"

# Arg parsing: optional scenario name, then optional run count.
SCENARIO="a2"
if [[ "${1:-}" == "a2" || "${1:-}" == "e2e" ]]; then SCENARIO="$1"; shift; fi
RUNS="${1:-${COFOUNDER_TEST_RUNS:-1}}"

export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com

BASE="$(mktemp -d)"
# Keep the throwaway projects on failure so they can be inspected; clean on success.
cleanup_base() { if [[ "$FAIL" -gt 0 ]]; then echo "kept for debugging: $BASE" >&2; else rm -rf "$BASE"; fi; }
trap cleanup_base EXIT

# Bootstrap a throwaway cofounder project with a clean local-remote git state.
# Arg 1 (optional): a PRD file to drop at docs/PRD.md before the first commit.
setup_project() {
  local prd="${1:-}"
  local p; p="$(mktemp -d "$BASE/cofoundertest.XXXXXX")"
  ( cd "$p" && bash "$INSTALL_SH" ) >"$p/.bootstrap.log" 2>&1
  if [[ -n "$prd" ]]; then mkdir -p "$p/docs"; cp "$prd" "$p/docs/PRD.md"; fi
  local bare="$p.git"; git init --bare -q -b main "$bare"
  ( cd "$p" && git init -b main -q && git add -A && git commit -qm init \
      && git remote add origin "$bare" && git push -u origin main -q ) >>"$p/.bootstrap.log" 2>&1
  printf '%s' "$p"
}

# Best-effort teardown of anything an e2e run may have left running.
cleanup_e2e() {
  local p="$1"
  pkill -f "$p" 2>/dev/null || true
  podman ps -aq --filter "name=$(basename "$p")" 2>/dev/null | xargs -r podman rm -f >/dev/null 2>&1 || true
}

# ---------------- scenario: a2 ----------------
A2_PROMPT="oi! tudo bem?"
A2_RUBRIC='This is a "cofounder" agent. On a neutral greeting it MUST:
(1) run the pre-flight check (cofounder-pre-flight-check / preflight.sh) before
    any other substantive work;
(2) adopt the cofounder persona and reply in the user'\''s language — here
    Portuguese, since the user said "oi";
(3) since no product requirements (PRD) exist yet, ASK the user what they want to
    build rather than inventing a project or writing code.
PASS only if all three hold.'

run_a2() {
  local i="$1" proj t verdict before
  proj="$(setup_project)"
  t="$proj/.transcript.jsonl"
  "$RUN_AGENT" --harness "$HARNESS" --cwd "$proj" --prompt "$A2_PROMPT" --out "$t" --timeout 300 || true
  before=$FAIL
  expect "[$i] transcript non-empty"    test -s "$t"
  expect "[$i] persona tag [Cofounder]" file_contains "$t" "[Cofounder]"
  expect "[$i] pre-flight ran"          grep -qiE 'cofounder-pre-flight-check|preflight' "$t"
  verdict="$("$JUDGE" "$t" "$A2_RUBRIC" 2>"$proj/.judge.log" || true)"
  echo "    judge: ${verdict:-<none>}"
  expect "[$i] judge verdict PASS"      test "$verdict" = PASS
  [[ $FAIL -eq $before ]]
}

# ---------------- scenario: e2e ----------------
E2E_PROMPT='Você já está em um projeto cofounder configurado. Leia docs/PRD.md e
implemente o aplicativo completo seguindo a stack do cofounder (Go + React, sqlc,
migrações). Faça backend e frontend, rode os testes (Go e frontend) e garanta que
o projeto compila e que os testes passam. NÃO faça deploy e NÃO deixe servidores
de desenvolvimento rodando em background — apenas implemente, compile e teste.'

E2E_RUBRIC='This transcript is a "cofounder" agent scaffolding an app from
docs/PRD.md (a small "tarefas" CRUD). PASS only if ALL hold:
(1) it implemented the PRD: a Go backend (migration for the tasks table, sqlc
    queries, the CRUD + /up handlers) and a React frontend page;
(2) it RAN the backend tests (go test) AND the frontend tests (vitest), and both
    passed (look for passing test output, not just files);
(3) it followed cofounder stack conventions (sqlc for queries, embedded
    migrations, mise for tools);
(4) it did NOT deploy.
Fail if tests were not actually run, or only stubs/TODOs were written.'

run_e2e() {
  local i="$1" proj t verdict before
  proj="$(setup_project "$HERE/fixtures/prd-tasks.md")"
  t="$proj/.transcript.jsonl"
  echo "    scaffolding (this takes several minutes)..."
  "$RUN_AGENT" --harness "$HARNESS" --cwd "$proj" --prompt "$E2E_PROMPT" --out "$t" --timeout 1500 || true

  before=$FAIL
  expect "[$i] transcript non-empty"  test -s "$t"
  expect "[$i] backend/ created"      test -d "$proj/backend"
  expect "[$i] frontend/ created"     test -d "$proj/frontend"
  # The Go module lives in backend/ per the tech-stack layout (fall back to root).
  local gomod_dir; gomod_dir=$([ -f "$proj/backend/go.mod" ] && echo "$proj/backend" || echo "$proj")
  expect "[$i] go build compiles"     bash -c "cd '$gomod_dir' && mise x -- go build ./... >'$proj/.gobuild.log' 2>&1"
  expect "[$i] tsc -b passes"         bash -c "cd '$proj/frontend' && mise x -- npx tsc -b >'$proj/.tsc.log' 2>&1"

  verdict="$("$JUDGE" "$t" "$E2E_RUBRIC" 2>"$proj/.judge.log" || true)"
  echo "    judge: ${verdict:-<none>}"
  expect "[$i] judge verdict PASS"    test "$verdict" = PASS

  cleanup_e2e "$proj"
  [[ $FAIL -eq $before ]]
}

# ---------------- driver ----------------
pass_runs=0
for i in $(seq 1 "$RUNS"); do
  echo "== $SCENARIO · run $i/$RUNS ($HARNESS) =="
  if [[ "$SCENARIO" == "e2e" ]]; then run_e2e "$i"; else run_a2 "$i"; fi
  [[ $? -eq 0 ]] && pass_runs=$((pass_runs + 1))
done

echo
echo "pass-rate: $pass_runs/$RUNS runs fully green"
summary "agent $SCENARIO ($HARNESS)"
