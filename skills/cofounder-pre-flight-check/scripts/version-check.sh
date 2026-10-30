#!/usr/bin/env bash
# Step 0 of the pre-flight check: compare the loaded cofounder version (the
# COFOUNDER_VERSION marker in ../SKILL.md) with the latest published one.
#
# Prefers the authenticated gh CLI (5,000 req/h) over anonymous curl (60 req/h
# per IP, easily exhausted behind a shared corporate NAT). The response is only
# pattern-matched for a version string, never executed or evaluated.
#
# Always exits 0 (a failed check must never block the session) and prints one of:
#   VERSION_CURRENT: <local> (via gh|curl)
#   VERSION_OUTDATED: local <local>, remote <remote> (via gh|curl)
#   VERSION_CHECK_SKIPPED: <reason>
set -uo pipefail

API_PATH="repos/locaweb/cofounder/contents/.claude-plugin/plugin.json"
ACCEPT="Accept: application/vnd.github.raw+json"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
local_version=$(grep -oE "COFOUNDER_VERSION: $SEMVER" "$here/../SKILL.md" 2>/dev/null | grep -oE "$SEMVER" | head -n1)
if [[ -z "$local_version" ]]; then
    echo "VERSION_CHECK_SKIPPED: COFOUNDER_VERSION marker not found"
    exit 0
fi

body="" via=""
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    body=$(gh api -H "$ACCEPT" "$API_PATH" 2>/dev/null) && via=gh || body=""
fi
if [[ -z "$body" ]] && command -v curl >/dev/null 2>&1; then
    body=$(curl -fsSL --max-time 10 -H "$ACCEPT" "https://api.github.com/$API_PATH" 2>/dev/null) && via=curl || body=""
fi

remote_version=$(printf '%s' "$body" \
    | grep -oE "\"version\"[[:space:]]*:[[:space:]]*\"$SEMVER\"" \
    | grep -oE "$SEMVER" | head -n1)
if [[ -z "$remote_version" ]]; then
    echo "VERSION_CHECK_SKIPPED: could not fetch the published version"
    exit 0
fi

# Numeric per-field sort; portable where `sort -V` is not (older macOS).
newest=$(printf '%s\n%s\n' "$local_version" "$remote_version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)
if [[ "$remote_version" != "$local_version" && "$newest" == "$remote_version" ]]; then
    echo "VERSION_OUTDATED: local $local_version, remote $remote_version (via $via)"
else
    echo "VERSION_CURRENT: $local_version (via $via)"
fi
exit 0
