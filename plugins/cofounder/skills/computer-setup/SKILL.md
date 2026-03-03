---
name: Computer Setup
description: >
  This skill should be used when the user asks to "set up my computer",
  "install dev tools", "set up mise", "set up podman", "install Homebrew",
  "install Scoop", "set up development environment", "install node",
  "install go", or needs to ensure all development prerequisites
  (Homebrew/Scoop, mise, podman, GH CLI) are installed and configured.
version: 0.1.0
---

# Computer Setup

Install and configure all development prerequisites: package manager, mise
(tool version manager), podman (container runtime), and GH CLI. Fully
idempotent — safe to re-run across sessions.

## Overview

This skill detects the current platform (macOS or Windows via git bash) and
walks through the installation of all required tools. Each step checks whether
the tool is already present before attempting installation.

## Detect Platform

```bash
uname -s 2>/dev/null || echo Windows
```

- `Darwin` → follow the **macOS** section
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

#### 3. Install and activate mise

```bash
brew install mise
```

This is a no-op if mise is already installed. Then ensure mise is activated in
the user's shell profile:

```bash
grep -q 'mise activate' ~/.zprofile || echo 'eval "$(mise activate zsh --shims)"' >> ~/.zprofile
```

#### 4. Install GH CLI

```bash
brew install gh
```

This is a no-op if gh is already installed.

#### 5. Restart Claude

**If any of steps 1-4 performed an install**, ask the user to restart Claude
so the new PATH takes effect. Tell them to come back to this same chat session
after restarting — they can find it by selecting the **Code** tab and looking
for past sessions in the sidebar. Otherwise skip to Phase 2.

### Phase 2 — Verify and set up (after restart)

#### 6. Verify Homebrew

```bash
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

Add `--memory 1024` if the computer has less than 16 GB of RAM. Then:

> **Rosetta prompt:** During `podman machine start`, a system
> window may appear asking to install Rosetta. Before the command is executed, tell the user to look for it on
> their Desktop (it may be hidden behind other windows) and press **Install** to
> proceed. Claude cannot interact with this window — the user must do it
> themselves. Wait for the user to confirm before continuing.

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
mkdir -p ~/test1 && cd ~/test1 && mise use node@24 && node --version && rm -rf ~/test1
```

#### 9. Verify GH CLI

```bash
gh version
```

---

## Windows

> **Note:** It may seem odd to use bash and `.bash_profile` on Windows —
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

### 2. Check Podman

```bash
podman version
```

If not installed:

```bash
winget install --exact --id RedHat.Podman --accept-source-agreements --accept-package-agreements
```

### 3. Install mise

```bash
mise version
```

If not installed:

```bash
winget install --exact --id jdx.mise --accept-source-agreements --accept-package-agreements
```

Then ensure mise is activated in the user's shell profile:

```bash
grep -q 'mise activate' ~/.bash_profile || echo 'eval "$(mise activate bash --shims)"' >> ~/.bash_profile
```

Then add the mise shims directory to the **Windows** PATH so that tools
installed by mise are visible to Claude Code (which launches from Windows, not
from bash):

```bash
powershell.exe -Command "[Environment]::SetEnvironmentVariable('Path', '$(cygpath -w "$LOCALAPPDATA/mise/shims")' + ';' + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')"
```

> `LOCALAPPDATA` is the default location mise uses on Windows when
> `XDG_DATA_HOME` is not set. If in doubt, run `mise doctor` and look for the
> `shims` entry to confirm the path.

### 4. Check GH CLI

```bash
gh version
```

If not installed:

```bash
winget install --exact --id GitHub.cli
```

### 5. Restart check

**If any of steps 2-4 performed an install**, ask the user to restart Claude
(File > Exit on top left). Tell them to come back to this same chat session
after restarting — they can find it by selecting the **Code** tab and looking
for past sessions in the sidebar. Otherwise continue — this is the key to minimizing restarts.

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
mkdir -p ~/test1 && cd ~/test1 && mise use node@24 && node --version && rm -rf ~/test1
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

- **Homebrew/mise/podman not found after install**: Restart Claude so the new PATH takes effect
- **Podman machine fails to start**: Check that virtualization is enabled (`sysctl kern.hv_support` on macOS). Ensure no conflicting hypervisor (e.g., Docker Desktop) holds the VM socket.
- **WSL issues on Windows**: "Default Version: 2" does not guarantee WSL2 is working — errors about missing components may follow. If the output mentions "Virtual Machine Platform" or similar, ask the user to run `wsl.exe --install --no-distribution` in PowerShell as Administrator, then reboot. Otherwise, use `wsl --install`.
- **Connectivity test fails**: The nginx container may need an extra second. Re-run the curl check. If it persists, check firewall rules and that port 18080 is free.

## Bundled Resources

None — all steps are performed inline.
