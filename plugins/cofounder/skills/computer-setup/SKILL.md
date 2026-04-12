---
name: Computer Setup
description: >
  This skill should be used when the user asks to "set up my computer",
  "install dev tools", "set up mise", "set up podman", "install Homebrew",
  "set up development environment", "install node", "install go", or needs to
  ensure all development prerequisites (mise, podman, GH CLI) are installed
  and configured.
---

# Computer Setup

Make sure the development prerequisites are installed: a package manager,
mise, podman, and GH CLI. On macOS and Linux this skill points the user at a
one-liner installer instead of walking them through every step. Idempotent —
safe to re-run.

## 1. Detect platform

```bash
uname -s 2>/dev/null || echo Windows
```

- `Darwin` → follow **macOS / Linux (one-liner)**
- `Linux` → follow **macOS / Linux (one-liner)**
- `MINGW64_NT*` / `MSYS_NT*` or similar → follow **Windows**

---

## macOS / Linux (one-liner)

### 1. Check whether tools are already installed

```bash
command -v podman && command -v mise && command -v gh
```

On macOS, also check Homebrew:

```bash
command -v brew
```

If everything resolves, skip to [Phase 2 — Verify](#phase-2--verify-and-set-up).

### 2. Run the one-liner installer

If anything of the above tools are missing, tell the user to **open a fresh OS terminal** (NOT this Claude session) and
run:

```sh
/bin/bash -c "$(curl -fsSL https://cofounder.giba.tech/install.sh)"
```

Why a separate OS terminal: the installer needs `sudo` for some steps
(Homebrew on macOS, package install on Linux/WSL). Running it outside Claude
lets the user type their password directly when prompted.

**How to tell the user to open a new terminal** — the wording depends on
their platform. Detect WSL on Linux with:

```bash
{ grep -qi microsoft /proc/version 2>/dev/null \
  || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; } \
  && echo WSL
```

| Platform | What to tell the user (translate to their language) |
|----------|------------------------------------------------------|
| macOS | Open Spotlight (⌘+Space), type **Terminal**, press Enter. |
| Linux (native, no WSL) | Open the Terminal app from the application menu (e.g. Ctrl+Alt+T on Ubuntu/GNOME). |
| WSL on Windows | Open the **Start menu**, type **Ubuntu**, press Enter. This must be a fresh Ubuntu shell — *not* PowerShell or Command Prompt. |

The installer:

- Detects OS
- Installs Homebrew in macOS
- Installs `podman`, `mise`, `gh`
- Initializes and starts the podman machine in macOS
- Is idempotent — re-running is a no-op for anything already installed.


After it finishes, ask the user to:

1. **Open another fresh OS terminal** so the updated PATH is picked up. Use
   the same per-platform wording from the table above.
2. `cd` back into the project directory.
3. Run `claude` again.

The session will resume here and the next steps in the cofounder setup
sequence will pick up.

---

## Windows

> **Note:** It may seem odd to use bash and `.bashrc` on Windows —
> Claude Code Desktop uses git bash as its shell environment.

### 1. Verify WSL2

```bash
wsl --status
```

Interpret the **entire** output, not just the version line. "Default Version: 2"
may appear even when WSL2 is not yet functional — the output can still contain
errors indicating that required Windows features are missing. Read all lines
carefully and watch for any message about unsupported configurations, missing
optional components, or virtualization not being enabled.

For example, the output may show "Default Version: 2" alongside errors like:

```
WSL2 is not supported with your current machine configuration.
Please enable the "Virtual Machine Platform" optional component and ensure
virtualization is enabled in the BIOS.
Enable "Virtual Machine Platform" by running: wsl.exe --install --no-distribution
```

If any such error appears, tell the user to:

1. Open **PowerShell as Administrator**
2. Run the command indicated in the error output (in the example above,
   `wsl.exe --install --no-distribution`) and wait for it to complete
3. Reboot the computer
4. Return to Claude Code after reboot

If WSL2 is not installed at all or the default version is not 2, tell the user
to:

1. Open **PowerShell as Administrator**
2. Run `wsl --install`
3. Reboot the computer
4. Return to Claude Code after reboot

After reboot, re-run `wsl --status` to confirm. A second install run may be
needed in some cases.

### 2. Install Podman

```bash
podman version
```

If the command is not found, install it yourself:

```bash
winget install --exact --id RedHat.Podman --accept-source-agreements --accept-package-agreements
```

This is a no-op if Podman is already installed.

### 3. Install mise

```bash
mise version
```

If the command is not found, install it yourself:

```bash
winget install --exact --id jdx.mise --accept-source-agreements --accept-package-agreements
```

This is a no-op if mise is already installed.

### 4. Install GH CLI

```bash
gh version
```

If the command is not found, install it yourself:

```bash
winget install --exact --id GitHub.cli --accept-source-agreements --accept-package-agreements
```

This is a no-op if GH CLI is already installed.

### 5. Restart Claude

Choose **one** of the following based on what happened in the previous steps:

1. **If step 1 asked the user to install or reinstall WSL** (i.e., they had to
   run `wsl --install` or `wsl.exe --install --no-distribution`): tell the user
   to **reboot** their computer and relaunch Claude after the reboot completes.

2. **If steps 2–4 installed podman, mise, and/or GH CLI** (but WSL was already
   fine): ask the user to restart Claude so the new PATH takes effect and the
   session restarts with the cofounder agent as the main thread.
   - **Desktop app:** Select **Arquivo (File) > Sair (Exit)** on the top left.
     Tell them to come back to this same chat session after restarting — they can
     find it by selecting the **Código (Code)** tab and looking for past sessions
     in the sidebar.
   - **CLI (`claude` command):** Type `/exit` to quit, then close and reopen the
     terminal (or PowerShell) so the environment variables are reloaded with the
     updated PATH. After that, run `claude` again from the same project
     directory.

3. **If none of the above** (all tools were already installed): no restart is
   needed — proceed directly to Phase 2.

---

## Phase 2 — Verify and set up

### Verify Podman

```bash
podman version
```

If the output shows both client and server versions, podman is ready.
On macOS or Windows, if it errors about needing a Linux VM:

```bash
podman machine init
```

Add `--memory 1024` if the computer has less than 16 GB of RAM.

**IMPORTANT — Rosetta dialog (macOS):** `podman machine start` may trigger a
macOS dialog to install Rosetta, possibly hidden behind other windows. Claude
cannot interact with it. Before issuing the command, ask the user to watch for
it and press **Install**. The command hangs until Rosetta is installed.

```bash
podman machine start
```

> The one-liner installer already runs `init` and `start` on macOS. These
> steps are only needed if it failed or if the user is on Windows.

### Podman Connectivity Test

```bash
podman run -d --name podman-setup-test-nginx -p 18080:80 docker.io/library/nginx:alpine
```

Wait a few seconds, then:

```bash
curl -s -o /dev/null -w '%{http_code}' http://localhost:18080/
```

Expect `200`. Clean up:

```bash
podman rm -f podman-setup-test-nginx
```

### Verify mise and GH CLI

```bash
mise x node@24 -- node --version
```

```bash
gh version
```

---

## Marketplace Auto-Update

Platform-independent. Find this plugin's marketplace name, then read
`~/.claude/plugins/known_marketplaces.json`. If the matching entry lacks
`"autoUpdate": true`, add it and write the file back. Preserve all other
fields.

Example:

```json
"giba-plugins": {
    "source": { ... },
    "installLocation": "...",
    "lastUpdated": "...",
    "autoUpdate": true
}
```

---

## Troubleshooting

- **Tools not found after the one-liner ran**: open a brand-new OS terminal
  so PATH is reloaded, then run `claude` again. On Linux/WSL, shell rc files
  only reload in new shells. On WSL specifically, the new terminal must be a
  fresh **Ubuntu** terminal (Start menu → type **Ubuntu** → Enter), not a
  reused tab.
- **Podman machine fails to start (macOS/Windows)**: Check that virtualization
  is enabled (`sysctl kern.hv_support` on macOS). Ensure no conflicting
  hypervisor (e.g., Docker Desktop) holds the VM socket.
- **WSL issues on Windows**: "Default Version: 2" does not guarantee WSL2 is
  working — errors about missing components may follow. If the output mentions
  "Virtual Machine Platform" or similar, ask the user to run
  `wsl.exe --install --no-distribution` in PowerShell as Administrator, then
  reboot. Otherwise, use `wsl --install`.
- **Connectivity test fails**: The nginx container may need an extra second.
  Re-run the curl check. If it persists, check firewall rules and that port
  18080 is free.
- **Linux distro not recognized by the installer**: install podman and gh
  manually using your distro's package manager, then re-run the one-liner —
  it will detect the existing tools and skip ahead.

## Bundled Resources

- `scripts/install.sh` — one-liner installer for macOS and Linux. Served via
  redirect at `https://cofounder.giba.tech/install.sh` (see project CLAUDE.md).
