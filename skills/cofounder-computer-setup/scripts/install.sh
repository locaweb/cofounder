#!/usr/bin/env bash
#
# cofounder installer — the single, idempotent onboarding entry point
# -------------------------------------------------------------------
# Two halves, both safe to re-run anywhere:
#
#   1. Tools (machine-level):
#        - macOS:  Homebrew, podman, mise, gh, and a running podman machine
#        - Linux:  podman (via the distro package manager), mise, gh
#        - WSL:    same as Linux — WSL Ubuntu reports as Linux to uname
#
#   2. Project bootstrap (when run inside a project directory):
#        - Installs the cofounder skills into the project via `npx skills`
#          (auto-detecting the installed agent: Claude / Codex / Cursor / …)
#        - Writes the AGENTS.md activation pointer (+ CLAUDE.md @import)
#        - Pins .claude/settings.json when Claude is detected
#        - Appends .gitignore entries for the vendored skills
#
# Idempotent — safe to re-run. Detects existing tools before installing and
# upserts managed regions instead of duplicating them.
#
# All user-facing output messages are in Brazilian Portuguese, since the
# cofounder's primary audience speaks pt-BR. Code comments stay in English
# to match the rest of the repo.
#
# Usage (run this in YOUR own OS terminal, not inside Claude — sudo prompts
# work naturally there). On WSL, that means a fresh Ubuntu terminal launched
# from the Windows Start menu, not PowerShell or Command Prompt. Run it from
# inside the project directory you want to set up:
#
#   /bin/bash -c "$(curl -fsSL https://cofounder.locaweb.com.br/install.sh)"
#
# After it finishes, open a new terminal (so PATH picks up the new tools),
# cd into your project, and open your agent (e.g. run `claude`).

set -euo pipefail

# ---------- output helpers ----------

if [[ -t 1 ]]; then
  C_BLUE=$'\033[1;34m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_RESET=$'\033[0m'
else
  C_BLUE='' C_GREEN='' C_YELLOW='' C_RED='' C_RESET=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%sok%s  %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s!!%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%sxx%s  %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# ---------- install state (drives the closing "próximos passos" message) ----------
# NEED_RESTART: set by any install step that ACTUALLY installs a tool — that
# tool won't be on the parent shell's PATH until a new terminal is opened
# (Homebrew in particular requires this). Generalist on purpose: if anything
# was newly installed, suggest a restart rather than guessing which tools need
# one. IN_PROJECT: whether we configured a project (ran inside a project dir)
# vs. ran in $HOME for machine setup only.
NEED_RESTART=0
IN_PROJECT=0

# True when running inside WSL (Windows Subsystem for Linux). On WSL, the
# kernel string contains "microsoft" / "Microsoft" / "WSL" — we check both
# /proc/version and /proc/sys/kernel/osrelease because some WSL builds expose
# the marker in only one of them.
detect_wsl() {
  if [[ -r /proc/version ]] && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    return 0
  fi
  if [[ -r /proc/sys/kernel/osrelease ]] && grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null; then
    return 0
  fi
  return 1
}

# ---------- macOS ----------

install_macos() {
  install_homebrew_macos
  install_brew_pkg podman
  install_brew_pkg mise
  install_brew_pkg gh
  setup_podman_machine_macos
}

install_homebrew_macos() {
  if have brew; then
    ok "Homebrew já está instalado"
    return
  fi
  info "Instalando o Homebrew (sua senha pode ser solicitada)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  NEED_RESTART=1
  # Make brew available for the rest of this script
  if ! have brew; then
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null \
         || /usr/local/bin/brew shellenv 2>/dev/null \
         || true)"
  fi
}

install_brew_pkg() {
  local pkg="$1"
  if have "$pkg"; then
    ok "$pkg já está instalado"
    return
  fi
  info "Instalando $pkg via Homebrew..."
  # HOMEBREW_NO_ASK: skip the dependency-confirmation prompt ("Do you want to
  # proceed? [y/n]") that recent Homebrew shows when a formula pulls deps — it
  # has no default, so Enter yields "Invalid input" and confuses non-tech users.
  HOMEBREW_NO_ASK=1 brew install "$pkg"
  NEED_RESTART=1
}

setup_podman_machine_macos() {
  # Check machine state directly — more reliable than `podman version` which
  # may fail to reach the server in non-interactive shells (curl | bash).
  if podman machine list --format '{{.Running}}' 2>/dev/null | grep -q 'true'; then
    ok "A máquina do Podman já está rodando"
    return
  fi

  # Init the machine if none exists yet.
  if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    info "Inicializando a máquina do Podman..."
    # Plain string (not bash array) for compatibility with macOS's bundled
    # /bin/bash 3.2 — under `set -u`, expanding an empty array errors out
    # there. The curl-pipe-sh invocation uses /bin/bash directly and ignores
    # this script's #!/usr/bin/env bash shebang.
    local mem_arg=""
    local mem_bytes
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    # Below 16 GB → ask the VM to use only 1 GB
    if (( mem_bytes > 0 && mem_bytes < 17179869184 )); then
      mem_arg="--memory 1024"
      info "Menos de 16 GB de RAM detectados — usando --memory 1024"
    fi
    # Intentional unquoted expansion so word-splitting separates the flag
    # from its value when mem_arg is non-empty, and yields zero args when empty.
    podman machine init $mem_arg
  fi

  warn "O macOS pode exibir agora uma janela para instalar o Rosetta (às vezes"
  warn "escondida atrás de outras janelas). Se ela aparecer, clique em Instalar e aguarde."
  info "Iniciando a máquina do Podman..."
  podman machine start || warn "podman machine start falhou — execute novamente após responder a qualquer prompt"
}

# ---------- Linux ----------

install_linux() {
  local distro=""
  local distro_like=""
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    distro="${ID:-}"
    distro_like="${ID_LIKE:-}"
  fi

  install_podman_linux "$distro" "$distro_like"
  install_mise_linux
  install_gh_linux "$distro" "$distro_like"
  install_playwright_chromium_deps_linux "$distro" "$distro_like"
}

# Match either ID or any token in ID_LIKE.
distro_family() {
  local distro="$1" distro_like="$2"
  case " $distro $distro_like " in
    *" debian "*|*" ubuntu "*) echo debian ;;
    *" fedora "*|*" rhel "*|*" centos "*) echo rhel ;;
    *" arch "*) echo arch ;;
    *" alpine "*) echo alpine ;;
    *" suse "*|*" opensuse "*) echo suse ;;
    *) echo "" ;;
  esac
}

install_podman_linux() {
  if have podman; then
    ok "podman já está instalado"
    return
  fi
  local family
  family=$(distro_family "$1" "$2")
  info "Instalando podman..."
  case "$family" in
    debian)
      sudo apt-get update
      sudo apt-get install -y podman
      ;;
    rhel)
      sudo dnf install -y podman
      ;;
    arch)
      sudo pacman -S --noconfirm podman
      ;;
    alpine)
      sudo apk add podman
      ;;
    suse)
      sudo zypper install -y podman
      ;;
    *)
      err "Não sei como instalar o podman nesta distribuição (ID='$1' ID_LIKE='$2')."
      err "Consulte https://podman.io/docs/installation#installing-on-linux, instale manualmente e execute este script novamente."
      exit 1
      ;;
  esac
  NEED_RESTART=1
}

install_mise_linux() {
  # mise.run installs to ~/.local/bin/mise but does NOT touch shell rc files
  # or PATH — it only prints instructions. We persist the PATH entry to
  # ~/.bashrc ourselves and source it so it's also valid for the rest of this
  # script run.
  if have mise || [[ -x "${HOME}/.local/bin/mise" ]]; then
    ok "mise já está instalado"
    persist_local_bin_on_path
    return
  fi
  info "Instalando mise..."
  curl -fsSL https://mise.run | sh
  NEED_RESTART=1
  persist_local_bin_on_path
}

# Append `export PATH="$HOME/.local/bin:$PATH"` to ~/.bashrc (idempotent —
# skips the append if the line is already there) for future shells, and
# manually export it for the current script session. We don't `source
# ~/.bashrc` here because most distro bashrc files short-circuit in
# non-interactive shells (PS1 / `$-` guards), which would silently skip the
# new export.
persist_local_bin_on_path() {
  local line='export PATH="$HOME/.local/bin:$PATH"'
  touch ~/.bashrc
  grep -qsxF "$line" ~/.bashrc || echo "$line" >> ~/.bashrc
  export PATH="$HOME/.local/bin:$PATH"
}

install_playwright_chromium_deps_linux() {
  # The tech-stack skill uses Playwright (Chromium headless) for visual checks.
  # On Linux, Chromium needs a handful of system libraries (libnspr4, libnss3,
  # libasound2, etc.). We install them here, while sudo is available
  # interactively, so the agent never has to ask the user for a password later.
  #
  # We delegate to `playwright install-deps`, which knows the correct package
  # list for the current distro/version (Ubuntu 24.04+ uses t64-suffixed names,
  # for example). That keeps us in sync with whatever Playwright currently
  # ships, instead of hardcoding a list that drifts over time.
  local family
  family=$(distro_family "$1" "$2")
  if [[ "$family" != "debian" ]]; then
    warn "Pulando dependências do Chromium do Playwright (suporte automático apenas em Debian/Ubuntu)"
    warn "  → se as checagens visuais falharem depois, instale as bibliotecas do Chromium manualmente"
    return
  fi
  # Cheap idempotency check: if a couple of canary libs from Playwright's list
  # are already in the linker cache, assume the rest are too.
  if ldconfig -p 2>/dev/null | grep -q 'libnspr4\.so' \
     && ldconfig -p 2>/dev/null | grep -q 'libnss3\.so'; then
    ok "Dependências do Chromium do Playwright já estão instaladas"
    return
  fi
  info "Instalando dependências de sistema do Chromium do Playwright..."
  info "  (usamos o install-deps oficial do Playwright — assim a lista de pacotes fica sempre atualizada)"
  # mise was just installed by install_mise_linux above, and that function
  # exports ~/.local/bin onto PATH for the rest of this script run.
  # `mise x node@24` fetches a temporary node if it isn't already installed.
  # `npx --yes` accepts the playwright download prompt non-interactively.
  mise x node@24 -- npx --yes playwright@latest install-deps chromium
}

install_gh_linux() {
  if have gh; then
    ok "gh já está instalado"
    return
  fi
  local family
  family=$(distro_family "$1" "$2")
  info "Instalando gh..."
  case "$family" in
    debian)
      sudo mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      sudo apt-get update
      sudo apt-get install -y gh
      ;;
    rhel)
      sudo dnf install -y 'dnf-command(config-manager)' || true
      sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
      sudo dnf install -y gh
      ;;
    arch)
      sudo pacman -S --noconfirm github-cli
      ;;
    alpine)
      sudo apk add github-cli
      ;;
    suse)
      sudo zypper addrepo https://cli.github.com/packages/rpm/gh-cli.repo || true
      sudo zypper ref
      sudo zypper install -y gh
      ;;
    *)
      err "Não sei como instalar o gh nesta distribuição (ID='$1' ID_LIKE='$2')."
      err "Consulte https://github.com/cli/cli/blob/trunk/docs/install_linux.md e instale manualmente."
      exit 1
      ;;
  esac
  NEED_RESTART=1
}

# ---------- project bootstrap ----------

COFOUNDER_REPO="locaweb/cofounder"
COFOUNDER_INSTALL_URL="https://cofounder.locaweb.com.br/install.sh"

BEGIN_MARKER="<!-- cofounder:begin -->"
END_MARKER="<!-- cofounder:end -->"

# upsert_managed_block <file> <body> — replace the managed region between the
# cofounder markers, creating the file or appending the block as needed.
# Idempotent; also rewrites any older managed block left by a past install.
upsert_managed_block() {
  local file="$1" body="$2"
  local block="$BEGIN_MARKER
$body
$END_MARKER"
  if [[ ! -f "$file" ]]; then
    printf '%s\n' "$block" > "$file"
    ok "criado $file"
    return
  fi
  if grep -q '<!-- cofounder:begin' "$file"; then
    local block_file
    block_file=$(mktemp)
    printf '%s\n' "$block" > "$block_file"
    awk -v blockfile="$block_file" '
      /<!-- cofounder:begin/ { skip=1 }
      skip && /<!-- cofounder:end -->/ {
        while ((getline line < blockfile) > 0) print line
        close(blockfile); skip=0; next
      }
      !skip { print }
    ' "$file" > "$file.tmp"
    rm -f "$block_file"
    mv "$file.tmp" "$file"
    ok "atualizado o bloco do cofounder em $file"
  else
    printf '\n%s\n' "$block" >> "$file"
    ok "adicionado o bloco do cofounder em $file"
  fi
}

# Pin .claude/settings.json (model / acceptEdits / permissions). Idempotent
# merge that preserves the user's other keys and drops the obsolete "agent"
# key. Uses node (provisioned by mise) so we don't depend on jq being present.
write_claude_settings() {
  mkdir -p "$PWD/.claude"
  local settings="$PWD/.claude/settings.json"
  local script
  script=$(mktemp)
  cat > "$script" <<'NODE'
const fs = require('fs');
const p = process.argv[2];
let cur = {};
try { cur = JSON.parse(fs.readFileSync(p, 'utf8')); } catch (e) {}
delete cur.agent;
cur.model = 'opus[1m]';
cur.defaultMode = 'acceptEdits';
const allow = new Set((cur.permissions && cur.permissions.allow) || []);
for (const a of ['Bash', 'Read', 'WebFetch']) allow.add(a);
cur.permissions = Object.assign({}, cur.permissions, { allow: [...allow] });
fs.writeFileSync(p, JSON.stringify(cur, null, 2) + '\n');
NODE
  mise x node@lts -- node "$script" "$settings"
  rm -f "$script"
  ok "configurado .claude/settings.json"
}

# Append .gitignore entries for the vendored skills (idempotent). The npx
# machinery stays the source of truth; the skills are not committed.
append_gitignore() {
  local gi="$PWD/.gitignore" entry
  touch "$gi"
  for entry in ".claude/skills/" ".agents/skills/" ".hermes/skills/" "skills-lock.json"; do
    grep -qxF "$entry" "$gi" || echo "$entry" >> "$gi"
  done
}

project_bootstrap() {
  # Home-dir guard: never inject the cofounder into $HOME (would activate it
  # globally). This is a machine-setup-only run; print_next_steps explains what
  # to do next.
  if [[ "$PWD" == "$HOME" ]]; then
    IN_PROJECT=0
    return
  fi
  IN_PROJECT=1

  info "Configurando o cofounder neste projeto..."

  # Non-universal agents (Claude, Hermes) keep skills in their OWN project dir
  # (.claude/skills, .hermes/skills) and don't read the shared store. The
  # npx-skills installer only symlinks into those dirs when they ALREADY EXIST
  # in the project — so we pre-create one ONLY when that agent is actually
  # installed for this user (its home dir is present). Users without it get no
  # stray .claude/ or .hermes/ directory.
  local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local hermes_home="${HERMES_HOME:-$HOME/.hermes}"
  if [[ -e "$claude_home" ]]; then
    write_claude_settings   # pins Claude settings and creates .claude/ as a side effect
  fi
  if [[ -e "$hermes_home" ]]; then
    mkdir -p "$PWD/.hermes"
  fi

  # Install to explicit, deterministic targets — no agent auto-detection:
  #   * universal                  → the shared .agents/skills store read by every
  #                                  open-convention agent (Codex, Cursor, Gemini,
  #                                  OpenCode, Cline, Replit, Amp, …).
  #   * claude-code, hermes-agent  → their own dirs; symlinked only when the
  #                                  matching dir was pre-created above, so users
  #                                  without that agent get no junk.
  # Passing -a explicitly also sidesteps the CLI's "nothing detected + -y →
  # install to all ~70 agents" fallback entirely.
  info "Instalando as skills do cofounder (via npx skills)..."
  mise x node@lts -- npx -y skills add "$COFOUNDER_REPO" --agent universal claude-code hermes-agent --skill '*' -y

  # AGENTS.md: activation pointer + resilience self-bootstrap (for a fresh clone
  # whose gitignored skills are absent and the installer hasn't been re-run yet).
  upsert_managed_block "$PWD/AGENTS.md" "You are operating as a cofounder. Your FIRST action this session — before responding to or acting on the user's message, even if it is a specific task, question, or feature request — MUST be to use the Skill tool to invoke the \`cofounder-playbook\` skill, then follow it as your operating instructions for the entire session. Do not begin the user's request until the playbook is loaded. (If the cofounder skills are not installed in this project, first install them by running \`/bin/bash -c \"\$(curl -fsSL $COFOUNDER_INSTALL_URL)\"\`, then invoke the playbook.)"

  # CLAUDE.md: @import so Claude (which doesn't read AGENTS.md natively) loads it.
  upsert_managed_block "$PWD/CLAUDE.md" "The cofounder operating instructions are maintained in @AGENTS.md — read and follow them."

  append_gitignore
  ok "Skills e configuração do projeto instaladas."
}

# ---------- next steps ----------

# Context-aware closing message. The installer runs as a child process and
# can't mutate the parent shell's PATH, so when it just installed tools it tells
# the user to open a new terminal — but ONLY when that's actually needed
# (NEED_RESTART). Wording stays harness-agnostic ("seu agente de IA"): the
# harness (Claude Code, etc.) is installed separately and the set will grow.
print_next_steps() {
  echo
  if [[ "$IN_PROJECT" == "1" ]]; then
    # Home-abbreviated path so the "cd" step shows e.g. `cd ~/meu-app`.
    local proj_display="$PWD"
    if [[ "$PWD" == "$HOME"/* ]]; then
      proj_display="~${PWD#"$HOME"}"
    fi
    if [[ "$NEED_RESTART" == "1" ]]; then
      ok   "Projeto configurado."
      warn "Feche o terminal (digite 'exit') e abra um novo para carregar as ferramentas"
      warn "Volte para esta pasta: cd $proj_display"
      warn "Inicie seu agente de IA (Claude, Codex etc.)"
    else
      ok "Projeto configurado! Inicie seu agente de IA nesta pasta para começar."
    fi
  else
    ok "Ferramentas prontas."
    if [[ "$NEED_RESTART" == "1" ]]; then
      warn "Feche o terminal (digite 'exit') e abra um novo para carregá-las antes de continuar."
    fi
    info "Para configurar seu primeiro projeto, em um terminal:"
    info "  mkdir ~/meu-app && cd ~/meu-app"
    info "  e rode este mesmo comando dentro da pasta do projeto."
  fi
}

# ---------- main ----------

main() {
  local os
  os="$(uname -s)"

  case "$os" in
    Darwin) install_macos ;;
    Linux)  install_linux ;;
    *)
      err "Sistema operacional não suportado: $os (este instalador suporta macOS e Linux)"
      exit 1
      ;;
  esac

  echo
  project_bootstrap

  print_next_steps
}

main "$@"
