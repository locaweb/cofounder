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

<!-- COFOUNDER_VERSION: 0.29.1 -->

The `COFOUNDER_VERSION` marker above contains the loaded version of the cofounder skills.

Run the bundled version check (resolve the path against this skill's directory, as in "Running the Check" below):

```bash
bash <this-skill-dir>/scripts/version-check.sh
```

It reads `.claude-plugin/plugin.json` from the GitHub API. It uses the authenticated `gh api` when `gh auth status` passes, which avoids the 60 requests/hour limit for anonymous calls. Otherwise it falls back to anonymous `curl`. It only compares version numbers and never executes the fetched content. It always exits `0` and prints one line:

- **`VERSION_OUTDATED: …`** (the remote is newer): Warn the user that the cofounder skills are outdated and ask them to update by running the command matching the line's `install:` field in their OS terminal. Tell them they **must start a new session** after updating — the current session still runs the outdated skills — and **stop**:

  - `install: skills`:

    ```sh
    mise x node@22 -- npx -y skills@1.7.4 add locaweb/cofounder --agent universal claude-code hermes-agent --skill '*' -y
    ```

  - `install: plugin <plugin>@<marketplace>` (a Claude Code plugin), with the reported `<plugin>@<marketplace>`:

    ```sh
    claude plugin update <plugin>@<marketplace>
    ```

    Alternatively, inside Claude Code: `/plugin` → **Installed** → select the plugin → **Update now**.

  - `install: codex-plugin <plugin>@<marketplace>` (a Codex plugin), with the reported `<marketplace>`:

    ```sh
    codex plugin marketplace upgrade <marketplace>
    ```

    Then, inside Codex, open `/plugins` and update (or reinstall) the plugin if it still shows the old version.

- **`VERSION_CURRENT: …`:** Proceed normally.
- **`VERSION_CHECK_SKIPPED: …`** (the fetch failed): Proceed without blocking the session. Do not treat a failed fetch as a reason to stop.

## Step 0b — Claude Code Settings (plugin installs)

When the cofounder is installed as a Claude Code plugin, `install.sh` may never have run in this project, so nothing pinned its `.claude/settings.json`. Tell the user in one sentence that you are configuring the project so that the cofounder can work without asking permission for every command, then run (resolve the path as in Step 0):

```bash
bash <this-skill-dir>/scripts/claude-settings.sh
```

It only acts on Claude Code plugin installs (on a Codex plugin it prints `SETTINGS_SKIPPED`): it merges `permissions.allow` (`Bash`, `Read`, `WebFetch`) into the project's `.claude/settings.json`, sets `model` (`opus[1m]`) and `permissions.defaultMode` (`acceptEdits`) only when they are absent (moving a root-level `defaultMode`, which Claude Code ignores, into `permissions`), and keeps every other key. It always exits `0` and prints one line:

- **`SETTINGS_UPDATED: …`:** Tell the user the settings were saved and take full effect in the next session, then proceed. Do not stop the session for this.
- **`SETTINGS_INVALID: …`:** The project's `.claude/settings.json` exists but is not valid JSON, so it was left untouched. Tell the user in plain language that their Claude settings file has a formatting error, that nothing was changed, and that they may be asked for permission more often until it is fixed. Offer to fix the formatting while keeping their content, then proceed.
- **`SETTINGS_CURRENT`** or **`SETTINGS_SKIPPED: …`:** Proceed normally without mentioning it.

## Step 0c — Codex Settings (Codex only)

Skip this step unless you are running in Codex (any install: plugin or `npx skills`). Codex opens a project read-only with no network until it is configured, and even its `workspace-write` sandbox blocks the writes outside the project that the cofounder's tools need (mise, Podman, the GitHub CLI, package caches). Run (resolve the path as in Step 0):

```bash
bash <this-skill-dir>/scripts/codex-settings.sh
```

It sets `sandbox_mode = "danger-full-access"` and `approval_policy = "on-request"` in the project's `.codex/config.toml` only when they are absent (keeping every other key), and marks the project trusted in the Codex home `config.toml` (without that, Codex ignores the project's `.codex/config.toml`). Both are keyed by the git root. It always exits `0` and prints one line:

- **`CODEX_SETTINGS_BLOCKED: …`:** The sandbox kept the file read-only and nothing was changed. Tell the user in one sentence that you need their approval once to configure the project so that the cofounder can install tools and run commands without asking every time, then run the same command again requesting escalated permissions (outside the sandbox). Handle that second run's line as below.
- **`CODEX_SETTINGS_UPDATED: …`:** Tell the user the settings were saved and take effect in the next session: they should close Codex and open it again in this folder. Until then, commands that write outside the project need their approval. Proceed; do not stop the session for this.
- **`CODEX_SETTINGS_UNTRUSTED`:** The user marked this project as untrusted in Codex, so nothing was changed and Codex keeps it read-only. Tell the user in plain language that the cofounder needs the folder to be trusted to install tools and run the app, and that they can trust it the next time Codex asks. Proceed.
- **`CODEX_SETTINGS_CURRENT`** or **`CODEX_SETTINGS_SKIPPED: …`:** Proceed normally without mentioning it.

## Step 0d — Project Activation (plugin installs)

The cofounder plugin does not start on its own: the user starts it once per project (with `/cofounder:iniciar` or by asking for it). This step makes the project start it automatically in every later session, by writing the activation pointer into the project's `AGENTS.md` (and a `CLAUDE.md` that imports it). Run (resolve the path as in Step 0):

```bash
bash <this-skill-dir>/scripts/project-activation.sh
```

It only acts on plugin installs (Claude Code or Codex), and only in an empty folder or in a cofounder project (one with `docs/PRD.md` or `docs/INFRASTRUCTURE.md`). It keeps everything outside the file's cofounder block. It always exits `0` and prints one line:

- **`ACTIVATION_UPDATED: …`:** Tell the user in one sentence that, from the next session on, the cofounder will start on its own in this project. Proceed.
- **`ACTIVATION_BLOCKED: …`:** The file is not writable from the sandbox (Codex before its settings take effect). Run the same command again requesting escalated permissions (outside the sandbox), then handle that second run's line as described here. If it is blocked again, proceed without mentioning it: the step runs again next session.
- **`ACTIVATION_SKIPPED: unclosed cofounder block in <file>`:** The file has a `<!-- cofounder:begin -->` line without the matching `<!-- cofounder:end -->`, so the script left it untouched to avoid deleting the user's content. Tell the user in one sentence that the cofounder will not start on its own in this project until they add the missing `<!-- cofounder:end -->` line (or remove the begin line) in `<file>`. Do not edit the file yourself. Proceed.
- **`ACTIVATION_CURRENT`** or any other **`ACTIVATION_SKIPPED: …`:** Proceed normally without mentioning it.

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
2. **Secret content guard**: aborts with `SECRETS_IN_CONTENT_DETECTED` when any of those files *contains* a high-confidence credential, whatever its name. This covers AWS access keys, GitHub/GitLab/Slack tokens, Stripe live keys, Anthropic and OpenAI keys, Google API keys, and private key blocks (including PGP). Placeholders are allowed: values containing `example` (such as `AKIAIOSFODNN7EXAMPLE`) or a run of 8 identical characters (such as `ghp_xxxxxxxx…`). The report lists `file:line` only, never the value. Remediation: move the value to `.env` and read it from the environment, and rotate the credential if it was ever pushed.
3. **Commit** any uncommitted local changes (staged or unstaged)
4. **Unpushed-commit guard**: aborts with `SECRETS_IN_UNPUSHED_COMMITS` when a local commit not yet on the remote (made by hand, or by the agent during a previous session) contains one of those credentials. It applies the same patterns and placeholder rules to every file those commits touched, and reports `commit:file:line` only. Remediation: rewrite those commits without the value (e.g. `git reset --soft <last pushed commit>`, move the value to `.env`, commit again), and rotate the credential if the commit was ever shared.
5. **Pull** remote commits using rebase to keep history linear
6. **Push** local commits to the remote

This ensures every session starts from a fully synchronized state.

**On failure:** The script reports a `GIT_SYNC_ERROR`, `SENSITIVE_FILES_DETECTED`, `SECRETS_IN_CONTENT_DETECTED` or `SECRETS_IN_UNPUSHED_COMMITS` with details. The user must resolve the issue manually and re-run the check.

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
- **`scripts/claude-settings.sh`**: pins the project's Claude Code settings on plugin installs (Step 0b)
- **`scripts/codex-settings.sh`**: configures the project's Codex sandbox and trust (Step 0c)
- **`scripts/project-activation.sh`**: writes the project's activation pointer on plugin installs (Step 0d)
- **`scripts/preflight.sh`** — Runs all environment validations and reports pass/fail with specific error codes
