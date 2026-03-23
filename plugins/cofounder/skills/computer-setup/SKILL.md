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

Install and configure all development prerequisites: package manager, mise
(tool version manager), podman (container runtime), and GH CLI. Fully
idempotent — safe to re-run across sessions.

## Overview

This skill detects the current platform (macOS, Linux, or Windows via git bash)
and walks through the installation of all required tools. Each step checks
whether the tool is already present before attempting installation.

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

**IMPORTANT — Rosetta dialog:** The `podman machine start` command below may trigger a macOS system dialog asking to install Rosetta. This dialog can appear hidden behind other windows. Claude cannot interact with it. Tell the user to watch for this dialog on their Desktop **as soon as the command starts running**, and press **Install** if it appears. If the command appears to hang, remind the user to look for the Rosetta dialog — the command will not complete until Rosetta is installed.

```bash
podman machine start
```

Run connectivity test:

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

#### 8. Verify mise works

```bash
mise x node@24 -- node --version
```

#### 9. Verify GH CLI

```bash
gh version
```

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

Verify that podman is working. On Linux, podman runs natively — no machine
init/start is needed.

Run connectivity test:

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

#### 6. Verify mise works

```bash
mise x node@24 -- node --version
```

#### 7. Verify GH CLI

```bash
gh version
```

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

If the user already needs to reboot the computer for WSL (step 1), skip
this step — the reboot already refreshes the PATH. Just tell them to open
Claude again after the reboot.

Otherwise, ask the user to restart Claude so the new PATH takes effect and the
session restarts with the cofounder agent as the main thread.

- **Desktop app:** Select **Arquivo (File) > Sair (Exit)** on the top left. Tell
  them to come back to this same chat session after restarting — they can find it
  by selecting the **Código (Code)** tab and looking for past sessions in the
  sidebar.
- **CLI (`claude` command):** Type `/exit` to quit, then close and reopen the
  terminal (or PowerShell) so the environment variables are reloaded with the
  updated PATH. After that, run `claude` again from the same project directory.

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

Run connectivity test:

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

### 7. Verify mise works

```bash
mise x node@24 -- node --version
```

### 8. Verify GH CLI

```bash
gh version
```

---

## Marketplace Auto-Update

Enable automatic updates for the marketplace this plugin belongs to. This step
is platform-independent and runs on both macOS and Windows.

### 1. Retrieve the marketplace name

Find the name of the marketplace to which this cofounder plugin belongs. Store
the result for the next step — referred to below as `<marketplace-name>`.

### 2. Enable auto-update

Read `~/.claude/plugins/known_marketplaces.json` and locate the entry whose key
matches `<marketplace-name>`. If the entry already has `"autoUpdate": true`, skip
this step. Otherwise, add `"autoUpdate": true` to that entry and write the file
back. Preserve all other fields and formatting.

Use the Read tool to inspect the file, then the Edit tool to add the key. For
example, if the marketplace name is `my-plugins` and the entry looks like:

```json
"my-plugins": {
    "source": { ... },
    "installLocation": "...",
    "lastUpdated": "..."
}
```

Add `"autoUpdate": true` as the last field in that object:

```json
"my-plugins": {
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
