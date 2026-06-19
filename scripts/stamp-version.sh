#!/usr/bin/env bash
# Stamps the version from plugin.json into the pre-flight-check skill marker.
# Run this after bumping the version in plugin.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$REPO_DIR/.claude-plugin/plugin.json"
VERSION=$(jq -r .version "$PLUGIN_JSON")
SKILL="$REPO_DIR/skills/cofounder-pre-flight-check/SKILL.md"

# Portable in-place edit: BSD sed (macOS) and GNU sed (Linux CI) disagree on
# the -i flag's syntax, so write through a temp file instead.
tmp=$(mktemp)
sed "s/COFOUNDER_VERSION: .*/COFOUNDER_VERSION: $VERSION -->/" "$SKILL" > "$tmp" && mv "$tmp" "$SKILL"

echo "Stamped version $VERSION into $(basename "$SKILL")"
