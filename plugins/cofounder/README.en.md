# Cofounder

A [Claude Code](https://docs.anthropic.com/en/docs/claude-code) plugin that acts as your co-founder — guiding you from idea to deployed web app, even if you've never written a line of code.

[Clique aqui para a versão em Português](README.md)

## Before you start

### macOS

1. Open Terminal and run:

   ```
   xcode-select --install
   ```

   This installs Git and other required command-line tools.

2. Install Claude:
   - [Claude Desktop](https://claude.com/download) (recommended) — or
   - [Claude Code](https://code.claude.com/docs/en/overview) (command line)

### Windows

1. Install [Claude Desktop](https://claude.com/download) (recommended) or [Claude Code](https://code.claude.com/docs/en/overview) (command line).

2. Install Git: in Claude Desktop, select the **Code** tab (**Control+3**) — it will display a message with a link to install Git for Windows. Follow the link and accept all defaults (the famous Next/Next/.../Finish).

3. Enable WSL2 (Windows Subsystem for Linux):
   1. Open **PowerShell as Administrator**
   2. Run `wsl --install`
   3. Reboot the computer

   After rebooting, run `wsl --status` and verify it shows "Default Version: 2". A second `wsl --install` run may be needed in some cases.

## What it does

Cofounder is an AI-powered co-founder that helps you:

- **Describe your idea** in plain language and get a structured Product Requirements Document
- **Build a full-stack web app** (Go + React + PostgreSQL) with guided development
- **Test your app** with automated end-to-end testing via Playwright
- **Deploy to the cloud** on Locaweb Cloud with GitHub Actions CI/CD

It handles environment setup, dependency management, Git/GitHub workflows, database containers, and deployment — explaining everything in accessible language along the way.

## Installation

### 🧑‍💻 Claude Desktop

1. Choose the Code selector (Command+3)
2. Open the sidebar
3. Click **Customize**
4. Click **Browse plugins**
5. Go to the **Personal** tab
6. Click **+**
7. Select **Add marketplace from GitHub**
8. Paste the URL: `gmautner/marketplace`
9. Click **Sync**
10. Click **Cofounder**
11. Click **Install**

### ⌨️ Claude Code

Add the marketplace and install the plugin:

```
/plugin marketplace add gmautner/marketplace
/plugin install cofounder
```

## Usage

### 🧑‍💻 Claude Desktop

1. Choose the Code selector (Command+3)
2. Open the sidebar
3. Click **(+) New Session**
4. Click the folder below the chat box
5. Click on **Select folder** or **Choose a different folder**
6. Click **New Folder**
7. Choose a name for your project
8. Click **Open**
9. In the chat box, type `/cofounder:install`

### ⌨️ Claude Code

Create a new project directory and start Claude Code:

```bash
mkdir my-app && cd my-app
claude
```

Activate the cofounder in your project:

```
/cofounder:install
```

## Demo

![Cofounder installation and usage on Claude Desktop](demo.webp)

This sets up the cofounder agent as the main thread for your project. From that point on, every Claude Code session in the project will automatically start with the cofounder managing your environment, requirements, and development workflow.

The setting is saved in `.claude/settings.json`, which you can commit to git so all collaborators get the same experience (they need the cofounder plugin installed too).

The agent will:

1. Set up your development environment (devbox, podman, GitHub repo)
2. Ask what you want to build
3. Create a PRD, generate tasks, and start building
4. Guide you through testing and deployment

Just describe what you want in your own words — no technical knowledge required.

## Commands

| Command | Description |
|---------|-------------|
| `/cofounder:install` | Install the cofounder as the main thread for this project (recommended) |
| `/cofounder:run` | Run the cofounder agent once without installing (advanced) |

## Skills included

| Skill | Purpose |
|-------|---------|
| `computer-setup` | Installs prerequisites (Homebrew/Scoop, mise, podman, GH CLI) |
| `pre-flight-check` | Validates environment prerequisites |
| `repo-setup` | Git + GitHub repository initialization |
| `tech-stack` | Full-stack app development (Go, React, PostgreSQL) |
| `frontend-design` | Distinctive UI/UX design guidance |
| `webapp-testing` | Playwright-based end-to-end testing |
| `app-deploy` | Deploy to Locaweb Cloud infrastructure |

## Tech stack

Applications built with this plugin use:

- **Backend:** Go stdlib (`net/http`), `pgx/v5`, `sqlc`
- **Frontend:** Vite + React + TypeScript, shadcn/ui, Tailwind CSS
- **Database:** PostgreSQL (via Supabase Postgres image with extensions)
- **Deployment:** Single Docker container, GitHub Actions CI/CD

## License

Apache 2.0 — see [LICENSE](../../LICENSE).
