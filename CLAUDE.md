The cofounder is a set of **skills** (under `skills/`, each named `cofounder-<x>`) distributed through two channels: installed into user projects via `npx skills` straight from this repo, and as a Claude Code / Codex plugin by `locaweb/cofounder-plugin`, whose `skills/` is copied from this repo's `v*` tags by a sync workflow. This repo is the only place where the skills, their scripts, the tests and the CI are developed; never edit the skills in the plugin repo. The skills are identical in both channels and detect at runtime how they were installed: the plugin-only scripts (`claude-settings.sh`, `project-activation.sh` in `cofounder-pre-flight-check`) do nothing on an `npx skills` install.

When modifying skill contents, present the changes first. Upon commit, bump the version in `.claude-plugin/plugin.json` (the version source-of-truth for the update gate, for `npx skills` discovery and for the plugin's version; keep this file). While in the 0.x.y generation: increment minor (x+1) for meaningful changes, increment patch (y+1) for small corrections. Add an entry to `CHANGELOG.md` for every version.

After bumping the version in `plugin.json`, run `scripts/stamp-version.sh` to propagate it to the `COFOUNDER_VERSION` marker in `skills/cofounder-pre-flight-check/SKILL.md`.

IMPORTANT: The `.claude/settings.json` file (which contains agent definitions and other project-level Claude Code configuration) MUST be committed to the repository. It is not a local-only file — it is shared project configuration that all contributors need.

## Release

GitHub (`locaweb/cofounder`) is the canonical repo; the old Azure DevOps repo no longer receives changes. Every change goes through a PR to `main`, and every release must:

1. Bump `.claude-plugin/plugin.json`, run `scripts/stamp-version.sh` and add the `CHANGELOG.md` entry (the version must not already be tagged on GitHub).
2. Merge the PR.
3. Run `scripts/tag-github-release.sh`. It creates the `v<version>` tag on GitHub's `main` via the API, which triggers `.github/workflows/release.yml`: the workflow fails if the tag differs from `plugin.json`, then publishes a GitHub Release with the `skills/` tarball, `install.sh` and `SHA256SUMS`, all with build provenance attestations.

The tag is also what carries a version to the plugin: `locaweb/cofounder-plugin` only picks up tagged versions. This includes the automatic `supabase/postgres` bump PRs: tag them after merging.

## install.sh — onboarding entry point + redirect

`skills/cofounder-computer-setup/scripts/install.sh` is the single onboarding script: it installs the dev tools **and** bootstraps a project (installs the skills via `npx skills add locaweb/cofounder`, writes the AGENTS.md pointer / CLAUDE.md `@import`, pins `.claude/settings.json` when Claude is detected, appends `.gitignore`). It is idempotent and run **before** the agent session opens. Note: the npx-skills CLI creates the project dir of every agent passed to `--agent`, so the installer passes `claude-code` / `hermes-agent` only when that agent is installed for the user. Its version is pinned in `SKILLS_CLI_VERSION`.

The cofounder-site app (`~/cofounder-site`, deployed at `cofounder.locaweb.com.br`) serves a 302 redirect from `https://cofounder.locaweb.com.br/install.sh` to the raw GitHub URL of this file. When changing the script's path or filename, update the redirect target in the cofounder-site Go backend (`backend/cmd/server/main.go`) to match.

