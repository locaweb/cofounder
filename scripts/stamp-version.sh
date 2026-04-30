#!/usr/bin/env bash
# Stamps the version from plugin.json into the pre-flight-check skill marker.
# Run this after bumping the version in plugin.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$REPO_DIR/plugins/cofounder"
VERSION=$(jq -r .version "$PLUGIN_DIR/.claude-plugin/plugin.json")
SKILL="$PLUGIN_DIR/skills/pre-flight-check/SKILL.md"

sed -i '' "s/COFOUNDER_VERSION: .*/COFOUNDER_VERSION: $VERSION -->/" "$SKILL"

echo "Stamped version $VERSION into $(basename "$SKILL")"
