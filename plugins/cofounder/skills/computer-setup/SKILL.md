---
name: Computer Setup
description: >
  This skill should be used when the user asks to "set up my computer",
  "install dev tools", "set up mise", "set up podman", "install Homebrew",
  "install Scoop", "set up development environment", "install node",
  "install go", or needs to ensure all development prerequisites
  (Homebrew/Scoop, mise, podman, GH CLI) are installed and configured.
  Supports macOS, Linux, and Windows.
---

# Computer Setup

Install and configure development prerequisites: package manager, mise, podman, and GH CLI. Idempotent — safe to re-run. Detects the platform and checks for existing tools before installing.

## Detect Platform

```bash
uname -s 2>/dev/null || echo Windows
```

- `Darwin` → follow the **macOS** section
- `Linux` → follow the **Linux** section
- `MINGW64_NT*` / `MSYS_NT*` or similar → follow the **Windows** section

---

## macOS

### Phase 1 — Install tools

#### 1. Install Homebrew

First check whether Homebrew is already installed:

```bash
command -v brew
```

If `brew` is found, skip to the next step.

If not found, extract the install command from https://brew.sh/ using the
WebFetch tool, then tell the user to open their **Terminal app** (not Claude)
and run that command there — it requires `sudo` which is not available inside
Claude. Ask the user to come back and confirm once the installation finishes.

#### 2. Install Podman

```bash
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
brew install podman
```

This is a no-op if podman is already installed.

#### 3. Install mise

```bash
brew install mise
```

This is a no-op if mise is already installed.

#### 4. Install GH CLI

```bash
brew install gh
```

This is a no-op if gh is already installed.

#### 5. Restart Claude

Ask the user to restart Claude so the new PATH takes effect and the session
restarts with the cofounder agent as the main thread.

- **Desktop app:** Press **Command+Q** or select **Claude > Sair (Quit)** on the
  upper left corner of the screen. Tell them to come back to this same chat
  session after restarting — they can find it by selecting the **Código (Code)**
  tab and looking for past sessions in the sidebar.
- **CLI (`claude` command):** Type `/exit` to quit, then close and reopen the
  terminal so the shell profile is reloaded with the updated PATH. After that,
  run `claude` again from the same project directory.

### Phase 2 — Verify and set up (after restart)

#### 6. Verify Homebrew

First, try running `brew --version` **without** evaluating `brew shellenv`:

```bash
brew --version
```

If this succeeds, Homebrew is already on the PATH — **do not prefix any
subsequent `brew` commands with the `eval "$(brew shellenv)"` pattern** for the
remainder of this session.

If the command fails (not found), fall back to the shellenv evaluation:

```bash
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null || /usr/local/bin/brew shellenv 2>/dev/null || true)"
brew --version
```

#### 7. Set up Podman machine

```bash
podman version
```

Interpret the output. If it shows client and server versions, podman is ready.
If it errors about needing a Linux VM:

```bash
podman machine init
```

Add `--memory 1024` if the computer has less than 16 GB of RAM.

**IMPORTANT — Rosetta dialog:** `podman machine start` may trigger a macOS dialog to install Rosetta, possibly hidden behind other windows. Claude cannot interact with it. Before issuing the command, ask the user to watch for it and press **Install**. The command hangs until Rosetta is installed.

```bash
podman machine start
```

Run the [Podman Connectivity Test](#podman-connectivity-test), then [Verify mise and GH CLI](#verify-mise-and-gh-cli).

---

## Linux

### Phase 1 — Install tools

#### 1. Install Podman

```bash
command -v podman
```

If `podman` is found, skip to the next step.

If not found, refer to https://podman.io/docs/installation#installing-on-linux
using the WebFetch tool and follow the specific instructions for the user's
Linux distribution. Detect the distro:

```bash
. /etc/os-release 2>/dev/null && echo "$ID"
```

Use the matching section from the Podman docs (e.g., Alpine, Arch, CentOS,
Debian, Fedora, Ubuntu, etc.).

#### 2. Install mise

```bash
command -v mise
```

If `mise` is found, skip to the next step.

If not found, install it. Do NOT run any `mise activate` commands.

```bash
curl https://mise.run | sh
```

#### 3. Install GH CLI

```bash
command -v gh
```

If `gh` is found, skip to the next step.

If not found, refer to https://github.com/cli/cli/blob/trunk/docs/install_linux.md
using the WebFetch tool (or clone `https://github.com/cli/cli.git` to
`/tmp/gh-cli-docs` and read `docs/install_linux.md` if WebFetch fails) and
follow the specific instructions for the user's Linux distribution.

#### 4. Restart Claude

**If any of steps 1-3 performed an install**, ask the user to **exit Claude**
and **log out from their Linux session** (then log back in). This is needed to
reload `.bashrc` so the new PATH takes effect. Tell them to come back to this
same project directory and start a new Claude session. Otherwise skip to
Phase 2.

### Phase 2 — Verify and set up (after restart)

#### 5. Set up Podman

```bash
podman version
```

Verify podman is working. On Linux, podman runs natively — no machine init/start needed.

Run the [Podman Connectivity Test](#podman-connectivity-test), then [Verify mise and GH CLI](#verify-mise-and-gh-cli).

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
   needed — proceed directly to step 6.

### 6. Set up Podman machine

After restart (or if no restart was needed):

```bash
podman version
```

Interpret the output. If it shows client and server versions, podman is ready.
If it errors about needing a Linux VM:

```bash
podman machine init
```

Add `--memory 1024` if the computer has less than 16 GB of RAM. Then:

```bash
podman machine start
```

Run the [Podman Connectivity Test](#podman-connectivity-test), then [Verify mise and GH CLI](#verify-mise-and-gh-cli).

---

## Podman Connectivity Test

Run this after podman is set up on any platform:

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

---

## Verify mise and GH CLI

```bash
mise x node@24 -- node --version
```

```bash
gh version
```

---

## Marketplace Auto-Update

Platform-independent. Find this plugin's marketplace name, then read `~/.claude/plugins/known_marketplaces.json`. If the matching entry lacks `"autoUpdate": true`, add it and write the file back. Preserve all other fields.

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

- **Homebrew/mise/podman not found after install**: Restart Claude so the new PATH takes effect. On Linux, also log out and back in to reload `.profile`.
- **Podman machine fails to start (macOS/Windows)**: Check that virtualization is enabled (`sysctl kern.hv_support` on macOS). Ensure no conflicting hypervisor (e.g., Docker Desktop) holds the VM socket.
- **WSL issues on Windows**: "Default Version: 2" does not guarantee WSL2 is working — errors about missing components may follow. If the output mentions "Virtual Machine Platform" or similar, ask the user to run `wsl.exe --install --no-distribution` in PowerShell as Administrator, then reboot. Otherwise, use `wsl --install`.
- **Connectivity test fails**: The nginx container may need an extra second. Re-run the curl check. If it persists, check firewall rules and that port 18080 is free.

## Bundled Resources

None — all steps are performed inline.
