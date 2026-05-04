---
name: Pre-Flight Check
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

<!-- COFOUNDER_VERSION: 0.21.2 -->

The `COFOUNDER_VERSION` marker above contains the loaded version of the cofounder plugin.

Use WebFetch to read `https://raw.githubusercontent.com/gmautner/marketplace/refs/heads/main/plugins/cofounder/.claude-plugin/plugin.json`. Compare its `version` field with the version in the marker.

- **Remote is newer:** The session **must not continue**. Tell the user a new version is available, direct them to **https://cofounder.giba.tech/docs/atualizacao**, and **stop**. After they update, they **must start a new session** — the current session runs the outdated plugin.
- **Versions match:** Proceed normally.
- **Check fails** (network error, etc.): Proceed — do not block the session.

## Step 0.5 — CLAUDE.md Sync

Run the injection script to ensure the project's CLAUDE.md has the current cofounder instructions:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/inject-claude-md.sh "$(pwd)" "${CLAUDE_PLUGIN_ROOT}"
```

This is idempotent — if CLAUDE.md is already up to date, it's a no-op. If the plugin was updated since the last session, this refreshes the managed section with the new content.

## Running the Check

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/pre-flight-check/scripts/preflight.sh
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

- The directory contains files or folders other than `.claude` and `.venv`
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

**Action:** Use the Skill tool to invoke `cofounder:computer-setup` and follow its instructions. After tools are installed, re-run the preflight check.

### 5. Git Remote Check

If no git remote is configured (or no git repo exists), the script prints:

```
NEEDS_REPO_SETUP: ...
```

**Action:** Use the Skill tool to invoke `cofounder:repo-setup` and follow its instructions.

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
