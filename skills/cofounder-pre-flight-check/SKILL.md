---
name: cofounder-pre-flight-check
description: >
  This skill should be used at the very start of every session and when the
  user asks to "check my environment", "run a pre-flight check", "validate
  setup requirements", "is my system ready", or before any cofounder project
  initialization. It verifies the working directory, dev tools, git state,
  and remote configuration.
---

# Pre-Flight Check

Validate that the current environment is suitable for project work.
This is the first skill invoked at session start.

## Step 0 — Version Check

<!-- COFOUNDER_VERSION: 0.23.0 -->

The `COFOUNDER_VERSION` marker above contains the loaded version of the cofounder skills.

Fetch `https://raw.githubusercontent.com/locaweb/cofounder/refs/heads/main/.claude-plugin/plugin.json` and compare its `version` field with the version in the marker.

- **Remote is newer:** The session **must not continue** on the outdated skills. Refresh them by running the universal install command:

  ```sh
  mise x node@lts -- npx -y skills add locaweb/cofounder --agent universal claude-code hermes-agent --skill '*' -y
  ```

  (Re-running `/bin/bash -c "$(curl -fsSL https://cofounder.giba.tech/install.sh)"` does the same thing and also refreshes the dev tools.) Then tell the user the cofounder was updated and that they **must start a new session** to load it — the current session still runs the outdated skills — and **stop**.
- **Versions match:** Proceed normally.
- **Fetch fails:** Ask the user for network permission, then retry. If it still fails, proceed without blocking the session.

## Running the Check

This skill bundles the preflight script at `scripts/preflight.sh`, relative to the
directory this `SKILL.md` lives in. Locate it from the skill's own directory and
run it with bash — resolve the path against the skill directory, not your current
working directory:

```bash
bash <this-skill-dir>/scripts/preflight.sh
```

The script exits `0` and prints `PREFLIGHT_PASSED` on success, or exits `1` and
prints `PREFLIGHT_FAILED` followed by one or more error lines on failure.

## Conditions Checked

### 1. Must Not Be in the Home Directory

Running from the user's home folder (`~`) risks polluting it with project files.

**On failure:** Recommend creating and navigating to a project subfolder first
(e.g., `mkdir ~/my-project && cd ~/my-project`).

### 2. No Pre-Existing Content Without a Git Repository

When **both** of these conditions are true simultaneously, the check fails:

- The directory contains files or folders other than `.claude`, `.venv`, `CLAUDE.md`, and `AGENTS.md`
- No local git repository has been initialized (`.git/` does not exist)

This prevents accidentally initializing a project on top of untracked existing
content.

**On failure:** Suggest using an empty directory, or initializing a git
repository first to acknowledge the existing content.

### 3. Git Sync

When the directory has a git repository **and** at least one remote is configured,
the script automatically synchronizes:

1. **Commit** any uncommitted local changes (staged or unstaged)
2. **Pull** remote commits using rebase to keep history linear
3. **Push** local commits to the remote

This ensures every session starts from a fully synchronized state.

**On failure:** The script reports a `GIT_SYNC_ERROR` with details (commit
failed, merge conflict on pull, or push rejected). The user must resolve the
issue manually and re-run the check.

### 4. Dev Tools Check

The script checks for `podman`, `mise`, and `gh`. If any are missing, it prints:

```
NEEDS_COMPUTER_SETUP: missing <tool1> <tool2> ...
```

**Action:** Use the Skill tool to invoke `cofounder-computer-setup` and follow its instructions. After tools are installed, re-run the preflight check.

### 5. Git Remote Check

If no git remote is configured (or no git repo exists), the script prints:

```
NEEDS_REPO_SETUP: ...
```

**Action:** Use the Skill tool to invoke `cofounder-repo-setup` and follow its instructions.

## Handling Failures

When the pre-flight check fails (`PREFLIGHT_FAILED`):

1. Display each error reason to the user in plain language
2. Provide the recommended remediation for each failure
3. **Do not proceed** — wait for the user to fix the issue and re-run

When the pre-flight check passes but prints `NEEDS_` flags:

1. Invoke the indicated skill(s) in order: `computer-setup` first, then `repo-setup`
2. After those complete, proceed with the session

## Bundled Resources

### Scripts

- **`scripts/preflight.sh`** — Runs all environment validations and reports pass/fail with specific error codes
