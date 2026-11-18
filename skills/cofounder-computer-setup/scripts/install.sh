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

# mise is installed from a pinned release binary checked against its SHA256,
# instead of piping https://mise.run into sh. To update: pick a release at
# https://github.com/jdx/mise/releases, set MISE_VERSION and copy the four
# hashes from that release's SHASUMS256.txt (the mise-<version>-linux-* lines).
# The file is signed (SHASUMS256.asc) by the mise release key
# 24853EC9F655CE80B48E6C3A8B81C9D17413A06D, listed at
# https://mise.jdx.dev/installing-mise.html; check the signature first.
MISE_VERSION="v2026.10.21"
MISE_SHA256_LINUX_X64="ccfe12d7a62c6fb9def2a20db1f210f13a51de881f21fd8c85db4b6312405d07"
MISE_SHA256_LINUX_X64_MUSL="2e0a76d246a2189505e3b116f0c85ec8ac7d42611a7eb805216f2c058aa8a4c7"
MISE_SHA256_LINUX_ARM64="a7c96627e56c075543fe1c1aafeb289d2588d6ddfd4d705fce4ae140c57e190c"
MISE_SHA256_LINUX_ARM64_MUSL="5ff3db329eb4e9c97e826b7303e333ce740f52d0ca33c0545435d6e484be0bcb"

install_mise_linux() {
  # Installs to ~/.local/bin/mise but does NOT touch shell rc files or PATH.
  # We persist the PATH entry to ~/.bashrc ourselves and export it so it's
  # also valid for the rest of this script run.
  if have mise || [[ -x "${HOME}/.local/bin/mise" ]]; then
    ok "mise já está instalado"
    persist_local_bin_on_path
    return
  fi
  local arch libc="" sha tmp
  case "$(uname -m)" in
    x86_64|amd64)  arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)
      err "Arquitetura não suportada pelo instalador do mise: $(uname -m)"
      exit 1
      ;;
  esac
  # musl distros (Alpine) cannot run the glibc build.
  if compgen -G '/lib/ld-musl-*' >/dev/null; then
    libc="-musl"
  fi
  case "${arch}${libc}" in
    x64)        sha="$MISE_SHA256_LINUX_X64" ;;
    x64-musl)   sha="$MISE_SHA256_LINUX_X64_MUSL" ;;
    arm64)      sha="$MISE_SHA256_LINUX_ARM64" ;;
    arm64-musl) sha="$MISE_SHA256_LINUX_ARM64_MUSL" ;;
  esac
  info "Instalando mise ${MISE_VERSION}..."
  tmp=$(mktemp)
  curl -fsSL -o "$tmp" \
    "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${arch}${libc}"
  if ! printf '%s  %s\n' "$sha" "$tmp" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$tmp"
    err "O mise baixado não confere com o SHA256 esperado. Instalação abortada."
    exit 1
  fi
  mkdir -p "${HOME}/.local/bin"
  chmod 755 "$tmp"
  mv "$tmp" "${HOME}/.local/bin/mise"
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
  # Capture first: under `set -o pipefail`, `ldconfig -p | grep -q` fails with
  # SIGPIPE (141) when grep exits early, so the check never passed.
  local libs
  libs="$(ldconfig -p 2>/dev/null || true)"
  if grep -q 'libnspr4\.so' <<<"$libs" && grep -q 'libnss3\.so' <<<"$libs"; then
    ok "Dependências do Chromium do Playwright já estão instaladas"
    return
  fi
  info "Instalando dependências de sistema do Chromium do Playwright..."
  info "  (usamos o install-deps oficial do Playwright — assim a lista de pacotes fica sempre atualizada)"
  # mise was just installed by install_mise_linux above, and that function
  # exports ~/.local/bin onto PATH for the rest of this script run.
  # `mise x node@24` fetches a temporary node if it isn't already installed.
  # `npx --yes` accepts the playwright download prompt non-interactively.
  # Pinned version reduces supply-chain exposure; update together with the e2e package.json.
  mise x node@24 -- npx --yes playwright@1.50.1 install-deps chromium
}

# Primary key fingerprints of the GitHub CLI apt repository keyring, as listed
# at https://github.com/cli/cli/blob/trunk/docs/install_linux.md. To update
# after a key rotation, replace this list with the one in that doc. These are
# public fingerprints, not secrets; gitleaks:allow keeps the secret scan (G2)
# from flagging them as an API key.
GH_KEY_FINGERPRINTS="2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325"  # gitleaks:allow

# gh_keyring_trusted <keyring> — succeed only when the keyring holds at least
# one primary key and every one of them is in GH_KEY_FINGERPRINTS. Subkeys are
# not listed: they are bound to their primary key by its signature.
gh_keyring_trusted() {
  local gnupghome fprs fpr
  gnupghome=$(mktemp -d)
  fprs=$(gpg --homedir "$gnupghome" --show-keys --with-colons "$1" 2>/dev/null \
    | awk -F: '$1 == "pub" { want = 1; next } $1 == "fpr" && want { print $10; want = 0 }')
  rm -rf "$gnupghome"
  [[ -n "$fprs" ]] || return 1
  for fpr in $fprs; do
    case " $GH_KEY_FINGERPRINTS " in
      *" $fpr "*) ;;
      *) return 1 ;;
    esac
  done
}

install_gh_linux() {
  if have gh; then
    ok "gh já está instalado"
    return
  fi
  local family keyring
  family=$(distro_family "$1" "$2")
  info "Instalando gh..."
  case "$family" in
    debian)
      if ! have gpg; then
        sudo apt-get update
        sudo apt-get install -y gnupg
      fi
      keyring=$(mktemp)
      curl -fsSL -o "$keyring" https://cli.github.com/packages/githubcli-archive-keyring.gpg
      if ! gh_keyring_trusted "$keyring"; then
        rm -f "$keyring"
        err "A chave do repositório do gh não confere com os fingerprints oficiais. Instalação abortada."
        exit 1
      fi
      sudo mkdir -p -m 755 /etc/apt/keyrings
      sudo install -m 644 "$keyring" /etc/apt/keyrings/githubcli-archive-keyring.gpg
      rm -f "$keyring"
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
# npm "skills" CLI used to install the skills. To update: pick a version at
# https://www.npmjs.com/package/skills?activeTab=versions and re-run
# tests/install/test-install.sh, which checks which agent dirs it creates.
SKILLS_CLI_VERSION="1.7.4"

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
  # Clean up explicitly rather than with `trap ... RETURN`: a RETURN trap set
  # inside a function stays armed after that function returns and fires again on
  # the NEXT function return, when the local it references is out of scope —
  # which aborts the installer under `set -u` before it prints the next steps.
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
  mise x node@lts -- node "$script" "$settings" || { rm -f "$script"; return 1; }
  rm -f "$script"
  ok "configurado .claude/settings.json"
}

# Append .gitignore entries for the vendored skills, common secret files, and
# IDE/OS/Python/build artifacts that preflight's `git add -A` would otherwise
# auto-commit (idempotent). Negation rules un-ignore template variants
# (.env.example etc.) so they can be committed safely. Order matters: negations
# must follow the pattern they override.
append_gitignore() {
  local gi="$PWD/.gitignore" entry
  touch "$gi"
  for entry in \
      ".claude/skills/" ".agents/skills/" ".hermes/skills/" "skills-lock.json" \
      ".env" ".env.*" "!.env.example" "!.env.sample" "!.env.template" \
      ".idea/" ".vscode/" ".DS_Store" "*.pyc" "__pycache__/" "dist/"; do
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
  # npx-skills installer creates the dir of every agent passed to --agent, so
  # we target one ONLY when that agent is actually installed for this user (its
  # home dir is present). Users without it get no stray .claude/ or .hermes/
  # directory.
  local claude_home="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  local hermes_home="${HERMES_HOME:-$HOME/.hermes}"
  local agents=(universal)
  if [[ -e "$claude_home" ]]; then
    write_claude_settings   # pins Claude settings and creates .claude/ as a side effect
    agents+=(claude-code)
  fi
  if [[ -e "$hermes_home" ]]; then
    mkdir -p "$PWD/.hermes"
    agents+=(hermes-agent)
  fi

  # Install to explicit, deterministic targets — no agent auto-detection:
  #   * universal                  → the shared .agents/skills store read by every
  #                                  open-convention agent (Codex, Cursor, Gemini,
  #                                  OpenCode, Cline, Replit, Amp, …).
  #   * claude-code, hermes-agent  → their own dirs, only when that agent is
  #                                  installed (see above).
  # Passing -a explicitly also sidesteps the CLI's "nothing detected + -y →
  # install to all ~70 agents" fallback entirely. The CLI version is pinned so
  # a new npm release never runs here unreviewed.
  info "Instalando as skills do cofounder (via npx skills)..."
  mise x node@lts -- npx -y "skills@${SKILLS_CLI_VERSION}" add "$COFOUNDER_REPO" --agent "${agents[@]}" --skill '*' -y

  # AGENTS.md: activation pointer + resilience self-bootstrap (for a fresh clone
  # whose gitignored skills are absent and the installer hasn't been re-run yet).
  upsert_managed_block "$PWD/AGENTS.md" "You are operating as a cofounder. Your FIRST action this session — before responding to or acting on the user's message, even if it is a specific task, question, or feature request — MUST be to use the Skill tool to invoke the \`cofounder-playbook\` skill, then follow it as your operating instructions for the entire session. Do not begin the user's request until the playbook is loaded. (If the cofounder skills are not installed in this project, first install them by running \`mise x node@22 -- npx -y skills add $COFOUNDER_REPO --agent universal claude-code hermes-agent --skill '*' -y\`, then invoke the playbook.)"

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
