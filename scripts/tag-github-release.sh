#!/usr/bin/env bash
# Last step of a release: creates the v<version> tag on GitHub's main, which
# triggers .github/workflows/release.yml. Run it after the version bump PR is
# merged. The tag is created through the API from main's own plugin.json, so it
# never depends on the state of a local checkout.
set -euo pipefail

REPO="locaweb/cofounder"

sha=$(gh api "repos/$REPO/commits/main" --jq .sha)
version=$(gh api -H "Accept: application/vnd.github.raw+json" \
  "repos/$REPO/contents/.claude-plugin/plugin.json?ref=$sha" | jq -r .version)

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "plugin.json on GitHub main has an invalid version: $version" >&2
  exit 1
fi
tag="v$version"

if gh api "repos/$REPO/git/ref/tags/$tag" >/dev/null 2>&1; then
  echo "$tag already exists on GitHub; bump plugin.json first" >&2
  exit 1
fi

gh api "repos/$REPO/git/refs" -f ref="refs/tags/$tag" -f sha="$sha" >/dev/null
echo "Created $tag at $sha"
echo "Release workflow: https://github.com/$REPO/actions/workflows/release.yml"
