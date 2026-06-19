#!/usr/bin/env bash
#
# Runs inside the clean Ubuntu container. Drives install.sh through the A0
# (tooling) and A1 (project bootstrap) scenarios and asserts deterministic
# side-effects. No -e: we want every assertion to run even after a failure.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

INSTALL_SH="${INSTALL_SH:-/work/scripts/install.sh}"
# shellcheck source=/dev/null
source "${ASSERT:-/work/tests/lib/assert.sh}"

LOG=/tmp/cofounder-logs
mkdir -p "$LOG"

# run_install <dir> <logname> — run install.sh with cwd=<dir>, capture output.
run_install() { ( cd "$1" && bash "$INSTALL_SH" ) >"$LOG/$2.log" 2>&1; }

echo "== A0: tooling install (clean machine) =="
run_install "$HOME" a0 || true
export PATH="$HOME/.local/bin:$PATH"
expect "podman installed"                  command -v podman
expect "gh installed"                      command -v gh
expect "mise binary present"               test -x "$HOME/.local/bin/mise"
expect "bashrc persists ~/.local/bin PATH" file_contains "$HOME/.bashrc" 'export PATH="$HOME/.local/bin:$PATH"'
expect "A0 prints 'Ferramentas prontas.'"  file_contains "$LOG/a0.log" "Ferramentas prontas."
refute "A0 in \$HOME does not bootstrap a project" test -e "$HOME/AGENTS.md"

echo "== A0: idempotent re-run =="
run_install "$HOME" a0b || true
expect "re-run: podman já está instalado"  file_contains "$LOG/a0b.log" "podman já está instalado"
expect "re-run: gh já está instalado"      file_contains "$LOG/a0b.log" "gh já está instalado"
expect "re-run: mise já está instalado"    file_contains "$LOG/a0b.log" "mise já está instalado"

echo "== A1: project bootstrap, universal only (no Claude) =="
U="$HOME/proj-uni"; mkdir -p "$U"
run_install "$U" a1uni || true
expect "AGENTS.md created"                  test -f "$U/AGENTS.md"
expect "AGENTS.md has begin marker"         file_contains "$U/AGENTS.md" "<!-- cofounder:begin -->"
expect "AGENTS.md points to playbook skill" file_contains "$U/AGENTS.md" "cofounder-playbook"
expect "CLAUDE.md has @AGENTS.md import"    file_contains "$U/CLAUDE.md" "@AGENTS.md"
expect ".gitignore lists .agents/skills/"   file_contains "$U/.gitignore" ".agents/skills/"
expect ".gitignore lists skills-lock.json"  file_contains "$U/.gitignore" "skills-lock.json"
expect "universal skills store created"     test -d "$U/.agents/skills"
refute "no .claude dir when Claude absent"  test -e "$U/.claude"

echo "== A1: project bootstrap with Claude detected =="
mkdir -p "$HOME/.claude"   # simulate Claude installed for this user
C="$HOME/proj-claude"; mkdir -p "$C"
run_install "$C" a1claude || true
expect ".claude/settings.json written"      test -f "$C/.claude/settings.json"
expect "settings pin model opus[1m]"        file_contains "$C/.claude/settings.json" '"opus[1m]"'
expect "settings defaultMode acceptEdits"   file_contains "$C/.claude/settings.json" '"acceptEdits"'
expect "settings allow Bash"                file_contains "$C/.claude/settings.json" '"Bash"'
expect "claude skills dir created"          test -d "$C/.claude/skills"

echo "== A1: idempotent re-run (no duplication) =="
run_install "$C" a1claudeb || true
expect "single AGENTS begin marker"         count_eq 1 "$C/AGENTS.md" "<!-- cofounder:begin -->"
expect "single .gitignore agents entry"     count_eq 1 "$C/.gitignore" ".agents/skills/"

echo "== A1: settings.json merge preserves user keys =="
M="$HOME/proj-merge"; mkdir -p "$M/.claude"
printf '{\n  "foo": "bar",\n  "permissions": { "allow": ["Custom"] }\n}\n' > "$M/.claude/settings.json"
run_install "$M" a1merge || true
expect "merge keeps custom top-level key"   file_contains "$M/.claude/settings.json" '"foo": "bar"'
expect "merge keeps custom permission"      file_contains "$M/.claude/settings.json" '"Custom"'
expect "merge adds model pin"               file_contains "$M/.claude/settings.json" '"opus[1m]"'

summary "install.sh (ubuntu clean)"
