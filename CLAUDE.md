The cofounder is distributed as a set of **skills** (under `skills/`, each named `cofounder-<x>`) installed into user projects via `npx skills` — not as a Claude/Codex plugin. When modifying skill contents, present the changes first. Upon commit, bump the version in `.claude-plugin/plugin.json` (kept solely as the version source-of-truth for the update gate and for `npx skills` discovery). While in the 0.x.y generation: increment minor (x+1) for meaningful changes, increment patch (y+1) for small corrections.

After bumping the version in `plugin.json`, run `scripts/stamp-version.sh` to propagate it to the `COFOUNDER_VERSION` marker in `skills/cofounder-pre-flight-check/SKILL.md`.

IMPORTANT: The `.claude/settings.json` file (which contains agent definitions and other project-level Claude Code configuration) MUST be committed to the repository. It is not a local-only file — it is shared project configuration that all contributors need.

## Sync Azure → GitHub + release

Azure DevOps is the canonical repo; GitHub (`locaweb/cofounder`) is the public one that `npx skills` and the install.sh redirect read from. The two histories share no commits, so a sync copies the changes onto a branch cut from GitHub's `main` and goes through a GitHub PR. Every sync must:

1. Bump `.claude-plugin/plugin.json` and run `scripts/stamp-version.sh` (the version must not already be tagged on GitHub).
2. Merge the sync PR on GitHub.
3. Run `scripts/tag-github-release.sh`. It creates the `v<version>` tag on GitHub's `main` via the API, which triggers `.github/workflows/release.yml`: the workflow fails if the tag differs from `plugin.json`, then publishes a GitHub Release with the `skills/` tarball, `install.sh` and `SHA256SUMS`, all with build provenance attestations.

## install.sh — onboarding entry point + redirect

`skills/cofounder-computer-setup/scripts/install.sh` is the single onboarding script: it installs the dev tools **and** bootstraps a project (installs the skills via `npx skills add locaweb/cofounder`, writes the AGENTS.md pointer / CLAUDE.md `@import`, pins `.claude/settings.json` when Claude is detected, appends `.gitignore`). It is idempotent and run **before** the agent session opens. Note: the npx-skills CLI creates the project dir of every agent passed to `--agent`, so the installer passes `claude-code` / `hermes-agent` only when that agent is installed for the user. Its version is pinned in `SKILLS_CLI_VERSION`.

The cofounder-site app (`~/cofounder-site`, deployed at `cofounder.locaweb.com.br`) serves a 302 redirect from `https://cofounder.locaweb.com.br/install.sh` to the raw GitHub URL of this file. When changing the script's path or filename, update the redirect target in the cofounder-site Go backend (`backend/cmd/server/main.go`) to match.

