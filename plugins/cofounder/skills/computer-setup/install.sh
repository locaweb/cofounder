#!/usr/bin/env bash
#
# cofounder computer-setup installer
# ----------------------------------
# Installs the development prerequisites needed by the cofounder plugin:
#   - macOS: Homebrew, podman, mise, gh, and a running podman machine
#   - Linux: podman (via the distro package manager), mise, gh
#
# Idempotent — safe to re-run. Detects existing tools before installing.
#
# Usage (run this in YOUR terminal, not inside Claude — sudo prompts work
# naturally there):
#
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/gmautner/marketplace/main/plugins/cofounder/skills/computer-setup/install.sh)"
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
    ok "Homebrew already installed"
    return
  fi
  info "Installing Homebrew (you may be prompted for your password)..."
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
    ok "$pkg already installed"
    return
  fi
  info "Installing $pkg via Homebrew..."
  brew install "$pkg"
}

setup_podman_machine_macos() {
  # If podman version shows a server, the machine is already running.
  if podman version 2>/dev/null | grep -qi '^server'; then
    ok "Podman machine already running"
    return
  fi

  # Init the machine if none exists yet.
  if ! podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    info "Initializing podman machine..."
    local -a mem_arg=()
    local mem_bytes
    mem_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    # Below 16 GB → ask the VM to use only 1 GB
    if (( mem_bytes > 0 && mem_bytes < 17179869184 )); then
      mem_arg=(--memory 1024)
      info "Detected <16 GB of RAM — using --memory 1024"
    fi
    podman machine init "${mem_arg[@]}"
  fi

  warn "macOS may now show a Rosetta install dialog (sometimes hidden behind"
  warn "other windows). If you see it, click Install and wait for it to finish."
  info "Starting podman machine..."
  podman machine start || warn "podman machine start failed — re-run after handling any prompts"
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
    ok "podman already installed"
    return
  fi
  local family
  family=$(distro_family "$1" "$2")
  info "Installing podman..."
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
      err "Don't know how to install podman on this distro (ID='$1' ID_LIKE='$2')."
      err "See https://podman.io/docs/installation#installing-on-linux and install manually, then re-run."
      exit 1
      ;;
  esac
}

install_mise_linux() {
  # mise.run installs to ~/.local/bin/mise, which may not be on PATH in a
  # non-interactive shell — check both the command and the expected binary.
  if have mise || [[ -x "${HOME}/.local/bin/mise" ]]; then
    ok "mise already installed"
    # Make mise available for the rest of this script run
    export PATH="${HOME}/.local/bin:${PATH}"
    return
  fi
  info "Installing mise..."
  curl -fsSL https://mise.run | sh
  export PATH="${HOME}/.local/bin:${PATH}"
}

install_gh_linux() {
  if have gh; then
    ok "gh already installed"
    return
  fi
  local family
  family=$(distro_family "$1" "$2")
  info "Installing gh..."
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
      err "Don't know how to install gh on this distro (ID='$1' ID_LIKE='$2')."
      err "See https://github.com/cli/cli/blob/trunk/docs/install_linux.md and install manually."
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
      err "Unsupported OS: $os (this installer supports macOS and Linux)"
      exit 1
      ;;
  esac

  echo
  ok "All done."
  echo
  info "Next steps:"
  echo "  1. Open a new terminal so PATH picks up the new tools."
  echo "  2. cd into your project directory."
  echo "  3. Run: claude"
}

main "$@"
