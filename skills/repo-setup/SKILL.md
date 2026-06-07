---
name: repo-setup
description: >
  This skill should be used when the user asks to "set up a repo", "create a GitHub repo",
  "initialize git", "create a remote repository", "push to GitHub", "log in to GitHub",
  "gh auth", "set up GitHub", or asks about initializing a local and remote repository
  and pushing it to GitHub.
---

# Repository Setup

Initialize a local git repository and create a matching remote on GitHub using
the GH CLI, with device-code authentication that works reliably in all
environments.

## Prerequisites

The **computer-setup** skill must have been run first — it installs `gh` and `git`.

A GitHub account is required before proceeding. If the user does not have one,
guide them through account creation:

1. Navigate to <https://github.com/>.
2. Click **Sign up** (or **Continue with Google** for social login).
3. Follow the prompts and verify the email address — without a verified email,
   repository creation will fail.

Recommend enabling two-factor authentication after sign-up. For more details,
see [Creating an account on GitHub](https://docs.github.com/en/get-started/start-your-journey/creating-an-account-on-github).

## Authentication

### Device Code Flow

Run `gh auth status` — interpret whether it shows the user as authenticated.

If not authenticated, run:

```bash
GH_FORCE_TTY=1 NO_COLOR=1 GH_PROMPT_DISABLED=1 gh auth login --hostname github.com --git-protocol https --scopes "repo,read:org,workflow" > /tmp/gh-auth.log 2>&1 & sleep 3 && cat /tmp/gh-auth.log
```

Retrieve the one-time code from the output and display it **very prominently**
to the user along with the URL https://github.com/login/device. For example:

> **GitHub login required!**
>
> Your one-time code is: **`XXXX-XXXX`**
>
> Open **https://github.com/login/device** in your browser and enter the code.

Ask the user to complete the browser authorization and confirm when done.

### Verifying Authentication

After the user confirms, verify:

```bash
gh auth status
```

## Repository Initialization

### Full Setup

**Before running the init script, check if a remote is already configured:**

```bash
git remote get-url origin 2>/dev/null
```

If `origin` is already set, the repo is fully configured — **do not ask the
user for a name or visibility, and skip the init script entirely.**

If no remote is configured, ask the user for:
- **Repository name** — default: the current folder name.
- **Visibility** — `private` (default) or `public`.

Then run the init script. It is bundled with this skill at `scripts/repo-init.sh`,
relative to the directory this `SKILL.md` lives in — locate it from the skill's own
directory (not your current working directory) and run it with bash:

```bash
bash <this-skill-dir>/scripts/repo-init.sh <repo-name> [private|public]
```

The script will:
1. Initialize a local git repo if `.git/` does not exist
2. Create an initial empty commit if the repo has no commits
3. Skip remote creation if `origin` is already configured locally
4. If the repo already exists on GitHub, add it as `origin` and push
5. Otherwise, create the GitHub repository with the given name and visibility (default: `private`), add it as `origin`, and push

### Manual Steps

If finer control is needed, run each step individually:

```bash
# Initialize local repo
git init

# Create remote and link it (from the project directory)
gh repo create <repo-name> --private --source=. --remote=origin --push
```

## Important Notes

- **Authentication must happen before repo creation.** Run the auth flow first
  if `gh auth status` fails.
- **Do not use `--web` flag** for `gh auth login` — it attempts to open a browser
  which may not work. The device code flow (default when `--web` is omitted) is
  more reliable.
- **Default visibility is private.** Always confirm with the user before creating
  a public repository.

## Bundled Resources

### Scripts

- **`scripts/repo-init.sh`** — Initializes local git repo and creates the matching GitHub remote in one step
