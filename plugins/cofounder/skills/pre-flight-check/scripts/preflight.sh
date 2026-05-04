#!/usr/bin/env bash
set -euo pipefail

errors=()

# 1. Home folder check — must not be running from ~
current_dir=$(pwd -P)
home_dir="$HOME"
if [[ "$current_dir" == "$home_dir" ]]; then
    errors+=("IN_HOME_DIR: Current directory is the user's home folder. Initialize the project within a subfolder (e.g., ~/<project-name>).")
fi

# 2. Pre-existing content without a git repo
#    Blocks only when BOTH conditions are true:
#      - The folder contains items other than .claude, .venv
#      - No local git repository has been initialized (.git/ absent)
has_other_content=false
has_git=false

[[ -d ".git" ]] && has_git=true

for item in * .[!.]* ..?*; do
    [[ -e "$item" ]] || continue
    case "$item" in
        .git|.claude|.venv|CLAUDE.md) continue ;;
    esac
    has_other_content=true
    break
done

if $has_other_content && ! $has_git; then
    errors+=("EXISTING_CONTENT_NO_GIT: Directory contains pre-existing files but no git repository. This looks like an attempt to initialize a project over existing content. Use an empty directory or initialize a git repo first.")
fi

# Report results
if [[ ${#errors[@]} -gt 0 ]]; then
    echo "PREFLIGHT_FAILED"
    for err in "${errors[@]}"; do
        echo "  - $err"
    done
    exit 1
fi

# 3. Git sync — commit/push local changes and pull remote commits
#    Only runs when a git repo with at least one remote exists.
if $has_git && [[ -n "$(git remote 2>/dev/null)" ]]; then
    current_branch=$(git symbolic-ref --short HEAD 2>/dev/null || true)
    if [[ -z "$current_branch" ]]; then
        echo "PREFLIGHT_FAILED"
        echo "  - GIT_SYNC_ERROR: HEAD is detached — cannot sync."
        exit 1
    fi

    # Resolve the upstream tracking ref (e.g. "origin/main") if configured
    upstream=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null || true)

    # Commit any outstanding local changes
    if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then
        echo "SYNC: Committing local changes..."
        git add -A
        git commit -m "Auto-sync: commit outstanding changes before session" --no-gpg-sign || {
            echo "PREFLIGHT_FAILED"
            echo "  - GIT_SYNC_ERROR: Failed to commit local changes."
            exit 1
        }
    fi

    if [[ -n "$upstream" ]]; then
        # Upstream is configured — use it for pull/push (handles name mismatches)
        echo "SYNC: Pulling remote changes (upstream: $upstream)..."
        git pull --rebase || {
            echo "PREFLIGHT_FAILED"
            echo "  - GIT_SYNC_ERROR: Pull failed — possible merge conflict. Resolve manually and re-run."
            exit 1
        }

        echo "SYNC: Pushing local commits..."
        git push || {
            echo "PREFLIGHT_FAILED"
            echo "  - GIT_SYNC_ERROR: Push failed — check remote access and try again."
            exit 1
        }
    else
        # No upstream — try origin/<branch> as a best-effort fallback
        echo "SYNC: No upstream configured, trying origin/$current_branch..."
        if git rev-parse --verify "origin/$current_branch" >/dev/null 2>&1; then
            git pull --rebase origin "$current_branch" || {
                echo "PREFLIGHT_FAILED"
                echo "  - GIT_SYNC_ERROR: Pull failed — possible merge conflict. Resolve manually and re-run."
                exit 1
            }
        fi

        git push --set-upstream origin "$current_branch" || {
            echo "PREFLIGHT_FAILED"
            echo "  - GIT_SYNC_ERROR: Push failed — check remote access and try again."
            exit 1
        }
    fi

    echo "SYNC: Repository is up to date."
fi

# 4. Check dev tools — report if any are missing so the caller can load computer-setup
missing_tools=()
command -v podman >/dev/null 2>&1 || missing_tools+=("podman")
command -v mise   >/dev/null 2>&1 || missing_tools+=("mise")
command -v gh     >/dev/null 2>&1 || missing_tools+=("gh")
if [[ ${#missing_tools[@]} -gt 0 ]]; then
    echo "NEEDS_COMPUTER_SETUP: missing ${missing_tools[*]}"
fi

# 5. Check git remote — report if none configured so the caller can load repo-setup
if $has_git; then
    if [[ -z "$(git remote 2>/dev/null)" ]]; then
        echo "NEEDS_REPO_SETUP: git repo exists but no remote configured"
    fi
else
    echo "NEEDS_REPO_SETUP: no git repository"
fi

echo "PREFLIGHT_PASSED"
exit 0
