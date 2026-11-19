<p align="center">
  <img src="https://raw.githubusercontent.com/locaweb/cofounder-plugin/e05efd3f3190f56d79fb018a4f444e7a0847c38c/shared/brand/icon-512.png" alt="cofounder" width="128" height="128">
</p>

# cofounder

An AI-powered co-founder that guides you from idea to a web app published on the internet — no programming experience required.

[Clique aqui para a versão em Português](README.md)

![cofounder in action](demo.webp)

## What it does

The cofounder is a set of [skills](skills/) for your coding agent (Claude Code, Codex, Cursor, Gemini, OpenCode and others). It talks to you in plain language, writes the product spec with you, builds the app, tests it, and deploys it to Locaweb Cloud.

This repository is where the skills are developed. There are two ways to install them:

- **Via `npx skills`**, with this repository's `install.sh`: works with any compatible agent and is described below.
- **As a Claude Code or Codex plugin**: see [locaweb/cofounder-plugin](https://github.com/locaweb/cofounder-plugin). The plugin ships the same skills, at the same version.

## Installation

Open a terminal in the folder where you want to create your project and run:

```bash
/bin/bash -c "$(curl -fsSL https://cofounder.locaweb.com.br/install.sh)"
```

If you prefer to check the script before running it, download `install.sh` from the [latest release](https://github.com/locaweb/cofounder/releases/latest), verify it as described in [Verifying a release](#verifying-a-release) and run `bash install.sh`.

The script is idempotent (safe to run again) and:

- installs the development tools (mise, Podman, GitHub CLI and others);
- installs the cofounder skills into the project via [`npx skills`](https://github.com/vercel-labs/skills);
- configures your agent to load the cofounder at the start of every session (`AGENTS.md` and `CLAUDE.md`, plus `.claude/settings.json` when Claude Code is installed).

Then open your agent in the same folder (for example, run `claude`) and say hi.

When run from your home folder (`$HOME`), the script only installs the tools and does not touch any project.

### Updating

At the start of every session, the cofounder checks for a new version and, when there is one, shows the update command. To update by hand, run in the project folder:

```bash
mise x node@22 -- npx -y skills@1.7.4 add locaweb/cofounder --agent universal claude-code hermes-agent --skill '*' -y
```

What changes in each version is in the [CHANGELOG](CHANGELOG.md).

## Use cases

- **"I have an idea for an app"** — the cofounder asks questions, writes a PRD and proposes the first version.
- **"Run the app on my computer"** — starts the database, backend and frontend locally so you can try it out.
- **"Add a login page" / "fix this bug"** — implements the change with automated tests and checks it visually.
- **"Put it on the internet"** — creates the GitHub repository, the preview and production environments, and deploys to Locaweb Cloud.
- **"Use my own domain"** — configures a custom domain on the production environment.

## Security

The skills are **static files installed locally** in your project: Markdown instructions and shell scripts that you can read before using. They do not download or execute unauthorized remote code. Every command runs on your machine, through your agent and with your permission. The tools installed by `install.sh` come from their official sources, with versions pinned and checksums or signing keys verified.

### Verifying a release

Each version is published as a [GitHub Release](https://github.com/locaweb/cofounder/releases) with `install.sh`, a tarball of the `skills/` directory and a `SHA256SUMS` file. The artifacts carry provenance attestations proving they were built by the `release.yml` workflow from a specific commit of this repository. To verify them, use an authenticated [GitHub CLI](https://cli.github.com):

```bash
VERSION=v0.29.1
gh release download "$VERSION" --repo locaweb/cofounder --dir "cofounder-$VERSION"
cd "cofounder-$VERSION"
sha256sum -c SHA256SUMS   # on macOS: shasum -a 256 -c SHA256SUMS
gh attestation verify install.sh --repo locaweb/cofounder
gh attestation verify "cofounder-skills-$VERSION.tar.gz" --repo locaweb/cofounder
```

If everything passes, run the verified `install.sh` with `bash install.sh`.

## Development

- **Skills:** each folder in [`skills/`](skills/) is one skill (`cofounder-<name>`), with its `SKILL.md` and, when needed, scripts and references.
- **Tests:** `bash tests/scripts/test-scripts.sh` runs the script tests. The other levels (container install, macOS, agent runs with a judge) are in [`tests/README.md`](tests/README.md).
- **Versioning:** every change to the skills bumps the version in `.claude-plugin/plugin.json`, runs `scripts/stamp-version.sh` and gets a [CHANGELOG](CHANGELOG.md) entry. Documentation-only changes, such as this README, do not get a version.
- **Release:** after the PR is merged, `scripts/tag-github-release.sh` creates the `v<version>` tag, which publishes the Release. [locaweb/cofounder-plugin](https://github.com/locaweb/cofounder-plugin) copies the skills from every new tag.

## License

Functional Source License (FSL-1.1-ALv2) — see [LICENSE](LICENSE).
