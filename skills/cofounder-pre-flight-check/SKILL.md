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

<!-- COFOUNDER_VERSION: 0.26.1 -->

The `COFOUNDER_VERSION` marker above contains the loaded version of the cofounder skills.

Run the bundled version check (resolve the path against this skill's directory, as in "Running the Check" below):

```bash
bash <this-skill-dir>/scripts/version-check.sh
```

It reads `.claude-plugin/plugin.json` from the GitHub API. It uses the authenticated `gh api` when `gh auth status` passes, which avoids the 60 requests/hour limit for anonymous calls. Otherwise it falls back to anonymous `curl`. It only compares version numbers and never executes the fetched content. It always exits `0` and prints one line:

- **`VERSION_OUTDATED: …`** (the remote is newer): Warn the user that the cofounder skills are outdated and ask them to update by running the command below in their OS terminal. Tell them they **must start a new session** after updating — the current session still runs the outdated skills — and **stop**:

  ```sh
  mise x node@22 -- npx -y skills add locaweb/cofounder --agent universal claude-code hermes-agent --skill '*' -y
  ```

- **`VERSION_CURRENT: …`:** Proceed normally.
- **`VERSION_CHECK_SKIPPED: …`** (the fetch failed): Proceed without blocking the session. Do not treat a failed fetch as a reason to stop.

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

1. **Sensitive file guard** — aborts if any untracked, staged, or modified file matches credential patterns (`.env` / `<name>.env` / `.env.*`, `id_rsa` and friends, `.npmrc`/`.netrc`/`.pypirc`, `.pem`, `.key`, `.secret`, `.p12`, `.pfx`, `.jks`, `.keystore`, `credentials*.json`, `secrets.yaml`). Template files (`.example`, `.sample`, `.template`, …) and deletions are ignored. The remediation depends on how the file is tracked: add it to `.gitignore` (untracked), `git restore --staged <file>` (staged), or `git rm --cached <file>` plus `.gitignore` (already tracked).
2. **Secret content guard**: aborts with `SECRETS_IN_CONTENT_DETECTED` when any of those files *contains* a high-confidence credential, whatever its name. This covers AWS access keys, GitHub/GitLab/Slack tokens, Stripe live keys, Anthropic keys, Google API keys and private key blocks. Placeholders are allowed: values containing `example` (such as `AKIAIOSFODNN7EXAMPLE`) or a run of 8 identical characters (such as `ghp_xxxxxxxx…`). The report lists `file:line` only, never the value. Remediation: move the value to `.env` and read it from the environment, and rotate the credential if it was ever pushed.
3. **Commit** any uncommitted local changes (staged or unstaged)
4. **Pull** remote commits using rebase to keep history linear
5. **Push** local commits to the remote

This ensures every session starts from a fully synchronized state.

**On failure:** The script reports a `GIT_SYNC_ERROR`, `SENSITIVE_FILES_DETECTED` or `SECRETS_IN_CONTENT_DETECTED` with details. The user must resolve the issue manually and re-run the check.

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

- **`scripts/version-check.sh`**: compares the loaded version with the published one (Step 0)
- **`scripts/preflight.sh`** — Runs all environment validations and reports pass/fail with specific error codes
