#!/usr/bin/env bash
# Stamps the version from plugin.json into the pre-flight-check skill marker,
# and keeps the legacy compatibility shim in sync.
# Run this after bumping the version in plugin.json.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_JSON="$REPO_DIR/.claude-plugin/plugin.json"
VERSION=$(jq -r .version "$PLUGIN_JSON")
SKILL="$REPO_DIR/skills/pre-flight-check/SKILL.md"

sed -i '' "s/COFOUNDER_VERSION: .*/COFOUNDER_VERSION: $VERSION -->/" "$SKILL"

echo "Stamped version $VERSION into $(basename "$SKILL")"

# Legacy compatibility shim. Clients installed before the root-level restructure
# (cofounder <= 0.21.10) run a pre-flight version check that fetches
# plugins/cofounder/.claude-plugin/plugin.json. Mirror the canonical manifest
# there so those clients still detect updates and get nudged to upgrade.
# Remove once pre-0.21.11 clients are no longer in the wild.
LEGACY_SHIM="$REPO_DIR/plugins/cofounder/.claude-plugin/plugin.json"
if [ -f "$LEGACY_SHIM" ]; then
  cp "$PLUGIN_JSON" "$LEGACY_SHIM"
  echo "Synced legacy shim at plugins/cofounder/.claude-plugin/plugin.json"
fi

# Codex plugin manifest. Codex loads the cofounder as a plugin via its own
# .codex-plugin/plugin.json (parallel to .claude-plugin/plugin.json); that
# manifest declares ./hooks/hooks.json and grants the CLAUDE_PLUGIN_ROOT alias.
# It carries extra keys (skills/hooks paths) so we can't cp the canonical over
# it — update only the version field and leave the rest intact.
CODEX_MANIFEST="$REPO_DIR/.codex-plugin/plugin.json"
if [ -f "$CODEX_MANIFEST" ]; then
  tmp=$(mktemp)
  jq --arg v "$VERSION" '.version = $v' "$CODEX_MANIFEST" > "$tmp" && mv "$tmp" "$CODEX_MANIFEST"
  echo "Synced Codex manifest version at .codex-plugin/plugin.json"
fi
