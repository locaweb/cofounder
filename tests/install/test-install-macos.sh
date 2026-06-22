#!/usr/bin/env bash
#
# Step 3 of the test plan (ideas/test-plan.md): the macOS leg of install.sh.
# Ports the Step 1 container scenarios (A0 tooling + A1 bootstrap) to a real,
# CLEAN Mac — macOS can't be containerized, so this runs on the host.
#
#   RUN THIS ON A THROWAWAY / BRAND-NEW MAC, in your own Terminal (NOT inside
#   Claude). It is DESTRUCTIVE to the host: it installs Homebrew, podman, mise
#   and gh, and inits + starts a podman machine. It does NOT uninstall them
#   afterward (that's the machine setup you wanted); it only cleans the temp
#   project dirs it creates.
#
# Self-contained on purpose (assert helpers are inlined) so you can copy just
# this one file to the new Mac — no need to clone the repo there:
#
#   scp tests/install/test-install-macos.sh you@newmac:~/   # or curl it
#   ssh you@newmac
#   bash ~/test-install-macos.sh
#
# It exercises the PUBLISHED one-liner's exact bytes (fetched once from the
# redirect, then run from $HOME for A0 and from temp dirs for A1). Override the
# source with INSTALL_URL=… or point at a local copy with INSTALL_SH=/path.
# Skip the confirmation prompt with CONFIRM=1.
#
# No `set -e`: we want every assertion to run even after an earlier failure.
set -uo pipefail

INSTALL_URL="${INSTALL_URL:-https://cofounder.locaweb.com.br/install.sh}"

# ---------- inlined assert helpers (mirror tests/lib/assert.sh) ----------
PASS=0
FAIL=0
_pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
_fail() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
# expect <desc> <command...>  — pass if the command succeeds
expect() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _pass "$d"; else _fail "$d"; fi; }
# refute <desc> <command...>  — pass if the command FAILS
refute() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then _fail "$d"; else _pass "$d"; fi; }
file_contains() { grep -qF "$2" "$1"; }
count_eq() { local n; n=$(grep -cF "$3" "$2" 2>/dev/null || echo 0); [ "$n" -eq "$1" ]; }
summary() { printf '\n%s: %d passed, %d failed\n' "${1:-RESULT}" "$PASS" "$FAIL"; [ "$FAIL" -eq 0 ]; }

# ---------- preconditions ----------
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "xx  This is the macOS leg — run it on a Mac (uname=$(uname -s))." >&2
  exit 1
fi

echo "============================================================"
echo " cofounder install.sh — macOS leg (Step 3)"
echo "------------------------------------------------------------"
echo " DESTRUCTIVE to this host: installs Homebrew, podman, mise,"
echo " gh and inits/starts a podman machine. Use a CLEAN/throwaway"
echo " Mac. Tools are NOT removed afterward."
echo "============================================================"
if [[ "${CONFIRM:-0}" != "1" ]]; then
  read -r -p "Proceed on THIS machine? [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted."; exit 1; }
fi

LOG="$(mktemp -d "${TMPDIR:-/tmp}/cofounder-macos-test.XXXXXX")"
PROJECTS="$(mktemp -d "${TMPDIR:-/tmp}/cofounder-macos-proj.XXXXXX")"
cleanup() { rm -rf "$PROJECTS"; echo "(logs kept at $LOG)"; }
trap cleanup EXIT
echo "logs → $LOG"
echo "temp projects → $PROJECTS"

# Fetch the installer once so every phase runs identical bytes.
INSTALL_SH="${INSTALL_SH:-$LOG/install.sh}"
if [[ ! -f "$INSTALL_SH" ]]; then
  echo "==> Fetching installer from $INSTALL_URL"
  curl -fsSL "$INSTALL_URL" -o "$INSTALL_SH" || { echo "xx  fetch failed"; exit 1; }
fi

# run_install <cwd> <logname>
run_install() { ( cd "$1" && bash "$INSTALL_SH" ) >"$LOG/$2.log" 2>&1; }

# ============================================================
echo
echo "== A0: tooling install (clean Mac) =="
echo "   (you may be prompted for your password and a Rosetta install — answer them)"
run_install "$HOME" a0 || true
# Tools land under the Homebrew prefix, not yet on this shell's PATH — load it.
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"

expect "brew installed"                          command -v brew
expect "brew prefix is /opt/homebrew (Apple Si)" test -x /opt/homebrew/bin/brew
expect "podman installed"                        command -v podman
expect "mise installed"                          command -v mise
expect "gh installed"                            command -v gh
expect "A0 prints 'Ferramentas prontas.'"        file_contains "$LOG/a0.log" "Ferramentas prontas."
refute "A0 in \$HOME does not bootstrap a project" test -e "$HOME/AGENTS.md"
expect "podman machine exists"                   bash -c "podman machine list --format '{{.Name}}' 2>/dev/null | grep -q ."
expect "podman machine is running"               bash -c "podman machine list --format '{{.Running}}' 2>/dev/null | grep -q true"

# Memory branch (only meaningful below 16 GB): the installer passes --memory 1024.
mem_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
if (( mem_bytes > 0 && mem_bytes < 17179869184 )); then
  expect "<16GB: machine inited with --memory 1024" file_contains "$LOG/a0.log" "--memory 1024"
else
  echo "  ----  (>=16GB RAM: --memory flag not expected; skipping that assert)"
fi

echo
echo "== A0: idempotent re-run =="
run_install "$HOME" a0b || true
expect "re-run: Homebrew já está instalado" file_contains "$LOG/a0b.log" "Homebrew já está instalado"
expect "re-run: podman já está instalado"   file_contains "$LOG/a0b.log" "podman já está instalado"
expect "re-run: mise já está instalado"     file_contains "$LOG/a0b.log" "mise já está instalado"
expect "re-run: gh já está instalado"       file_contains "$LOG/a0b.log" "gh já está instalado"
expect "re-run: máquina do Podman já está rodando" file_contains "$LOG/a0b.log" "já está rodando"

# ============================================================
# This Mac has Claude Code installed (~/.claude present), so A1 exercises the
# Claude-detected path. The universal-only branch is covered by the Step 1
# container suite and is not reachable here.
echo
echo "== A1: project bootstrap with Claude detected =="
expect "precondition: ~/.claude exists" test -e "$HOME/.claude"
C="$PROJECTS/proj-claude"; mkdir -p "$C"
run_install "$C" a1claude || true
expect "AGENTS.md created"                  test -f "$C/AGENTS.md"
expect "AGENTS.md has begin marker"         file_contains "$C/AGENTS.md" "<!-- cofounder:begin -->"
expect "AGENTS.md points to playbook skill" file_contains "$C/AGENTS.md" "cofounder-playbook"
expect "CLAUDE.md has @AGENTS.md import"    file_contains "$C/CLAUDE.md" "@AGENTS.md"
expect ".gitignore lists .agents/skills/"   file_contains "$C/.gitignore" ".agents/skills/"
expect ".gitignore lists skills-lock.json"  file_contains "$C/.gitignore" "skills-lock.json"
expect ".claude/settings.json written"      test -f "$C/.claude/settings.json"
expect "settings pin model opus[1m]"        file_contains "$C/.claude/settings.json" '"opus[1m]"'
expect "settings defaultMode acceptEdits"   file_contains "$C/.claude/settings.json" '"acceptEdits"'
expect "settings allow Bash"                file_contains "$C/.claude/settings.json" '"Bash"'
expect "claude skills dir created"          test -d "$C/.claude/skills"
expect "universal skills store created"     test -d "$C/.agents/skills"

echo
echo "== A1: idempotent re-run (no duplication) =="
run_install "$C" a1claudeb || true
expect "single AGENTS begin marker"  count_eq 1 "$C/AGENTS.md" "<!-- cofounder:begin -->"
expect "single .gitignore agents entry" count_eq 1 "$C/.gitignore" ".agents/skills/"

echo
echo "== A1: settings.json merge preserves user keys =="
M="$PROJECTS/proj-merge"; mkdir -p "$M/.claude"
printf '{\n  "foo": "bar",\n  "permissions": { "allow": ["Custom"] }\n}\n' > "$M/.claude/settings.json"
run_install "$M" a1merge || true
expect "merge keeps custom top-level key" file_contains "$M/.claude/settings.json" '"foo": "bar"'
expect "merge keeps custom permission"    file_contains "$M/.claude/settings.json" '"Custom"'
expect "merge adds model pin"             file_contains "$M/.claude/settings.json" '"opus[1m]"'

echo
echo "Note: Rosetta is a GUI install prompt and isn't asserted here — confirm"
echo "manually that it appeared (or was already present) during A0."

summary "install.sh (macOS clean)"
