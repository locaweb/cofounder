#!/usr/bin/env bash
set -euo pipefail

# Initialize a local git repo and create a matching remote on GitHub.
#
# Usage: bash repo-init.sh <repo-name> [visibility]
#   repo-name  : Name for the GitHub repository (e.g. "my-web-app")
#   visibility : "private" (default) or "public"

REPO_NAME="${1:?Usage: repo-init.sh <repo-name> [private|public]}"
VISIBILITY="${2:-private}"

# Validate visibility
if [[ "$VISIBILITY" != "private" && "$VISIBILITY" != "public" ]]; then
  echo "ERROR: visibility must be 'private' or 'public', got '$VISIBILITY'" >&2
  exit 1
fi

# Ensure gh is authenticated
if ! gh auth status &>/dev/null; then
  echo "ERROR: Not authenticated with GitHub. Run 'gh auth login' first." >&2
  exit 1
fi

# Initialize local git repo if needed
if [ ! -d .git ]; then
  echo "Initializing local git repository..."
  git init
fi

# Create initial commit if repo is empty
if ! git rev-parse HEAD &>/dev/null; then
  echo "Creating initial commit..."
  git commit --allow-empty -m "Initial commit"
fi

# Check if remote 'origin' already exists locally
if git remote get-url origin &>/dev/null; then
  echo "Remote 'origin' already set to: $(git remote get-url origin)"
  echo "Skipping remote creation."
  exit 0
fi

# Check if the repo already exists on GitHub
if gh repo view "$REPO_NAME" &>/dev/null; then
  echo "Repository '$REPO_NAME' already exists on GitHub."
  REMOTE_URL="$(gh repo view "$REPO_NAME" --json url --jq .url)"
  echo "Adding existing remote as origin: $REMOTE_URL"
  git remote add origin "$REMOTE_URL"
  BRANCH="$(git branch --show-current)"
  # Pull remote history first, then push
  git fetch origin
  git pull --rebase origin "$BRANCH" 2>/dev/null || true
  git push -u origin "$BRANCH"
else
  # Create the remote repository on GitHub
  echo "Creating $VISIBILITY repository '$REPO_NAME' on GitHub..."
  gh repo create "$REPO_NAME" \
    "--$VISIBILITY" \
    --source=. \
    --remote=origin \
    --push
fi

echo ""
echo "Repository created and pushed:"
echo "  Local:  $(pwd)"
echo "  Remote: $(git remote get-url origin)"
