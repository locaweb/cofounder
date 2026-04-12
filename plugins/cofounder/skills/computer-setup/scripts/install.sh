#!/usr/bin/env bash
#
# cofounder computer-setup installer
# ----------------------------------
# Installs the development prerequisites needed by the cofounder plugin:
#   - macOS:    Homebrew, podman, mise, gh, and a running podman machine
#   - Linux:    podman (via the distro package manager), mise, gh
#   - WSL:      same as Linux — WSL Ubuntu reports as Linux to uname
#
# Idempotent — safe to re-run. Detects existing tools before installing.
#
# All user-facing output messages are in Brazilian Portuguese, since the
# cofounder plugin's primary audience speaks pt-BR. Code comments stay in
# English to match the rest of the repo.
#
# Usage (run this in YOUR own OS terminal, not inside Claude — sudo prompts
# work naturally there). On WSL, that means a fresh Ubuntu terminal launched
# from the Windows Start menu, not PowerShell or Command Prompt:
#
#   /bin/bash -c "$(curl -fsSL https://cofounder.giba.tech/install.sh)"
#
# After it finishes, open a new terminal (so PATH picks up the new tools),
# cd into your project, and run `claude`.

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
  brew install "$pkg"
}

setup_podman_machine_macos() {
  # If podman version shows a server, the machine is already running.
  if podman version 2>/dev/null | grep -qi '^server'; then
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
  ok "Tudo pronto."
  echo
  info "Próximos passos:"
  if detect_wsl; then
    echo "  1. Feche este terminal digitando: exit"
    echo "  2. Abra um novo terminal Ubuntu (Menu Iniciar → digite Ubuntu → Enter)"
    echo "     Não use PowerShell nem Prompt de Comando."
  elif [[ "$os" == "Darwin" ]]; then
    echo "  1. Encerre o Terminal com ⌘+Q"
    echo "  2. Abra um novo Terminal (Spotlight com ⌘+Espaço → Terminal → Enter)"
    echo "  (Pode ignorar a sugestão do Homebrew de editar ~/.zprofile —"
    echo "   /etc/paths.d/homebrew já deixa o brew disponível em novos shells.)"
  else
    echo "  1. Feche este terminal digitando: exit"
    echo "  2. Abra um novo terminal para que o novo PATH seja carregado."
  fi
}

main "$@"
