#!/usr/bin/env bash
# Plugin installs only: pins the project's .claude/settings.json the way
# install.sh's write_claude_settings does for an `npx skills` install. Keep the
# two in sync. Unlike install.sh (run once), this runs every session, so model
# and defaultMode are only set when absent and a user's own choice survives.
#
# Always exits 0 (a failure must never block the session) and prints one of:
#   SETTINGS_CURRENT
#   SETTINGS_UPDATED: .claude/settings.json
#   SETTINGS_INVALID: .claude/settings.json   (unreadable or not a JSON object; left untouched)
#   SETTINGS_SKIPPED: <reason>
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same plugin detection as version-check.sh: a plugin root above the skill.
if [[ ! -f "$here/../../../.claude-plugin/plugin.json" ]]; then
    echo "SETTINGS_SKIPPED: not a plugin install (install.sh pins the settings)"
    exit 0
fi
# A Codex plugin is a copy of the same repo, so it also has the Claude
# manifest; same Codex cache detection as version-check.sh.
case "$(cd "$here/../../.." && pwd)" in
    "${CODEX_HOME:-$HOME/.codex}"/plugins/cache/*/*/*|*/.codex/plugins/cache/*/*/*)
        echo "SETTINGS_SKIPPED: Codex plugin install"
        exit 0 ;;
esac
if [[ "$PWD" == "$HOME" ]]; then
    echo "SETTINGS_SKIPPED: in the home directory"
    exit 0
fi

if command -v node >/dev/null 2>&1; then
    run=(node)
elif command -v mise >/dev/null 2>&1; then
    run=(mise x node@lts -- node)
else
    echo "SETTINGS_SKIPPED: node not available"
    exit 0
fi

"${run[@]}" -e '
const fs = require("fs");
const path = require("path");
const p = process.argv[1];
let before = null, cur = {};
// Only a missing file starts from scratch: one that cannot be read or parsed
// belongs to the user and must not be overwritten with just our keys.
let ok = true;
try { before = fs.readFileSync(p, "utf8"); cur = JSON.parse(before); } catch (e) { ok = e.code === "ENOENT"; }
if (!ok || cur === null || typeof cur !== "object" || Array.isArray(cur)) { console.log("SETTINGS_INVALID: .claude/settings.json"); process.exit(0); }
// Older cofounder installs activated it through "agent"; any other value
// belongs to the user and stays.
if (cur.agent === "cofounder" || cur.agent === "cofounder:cofounder") delete cur.agent;
if (cur.model === undefined) cur.model = "opus[1m]";
// Claude Code reads defaultMode only under permissions; a root-level one (as
// older installers wrote) is ignored, so move it there.
const perms = Object.assign({}, cur.permissions);
if (perms.defaultMode === undefined) perms.defaultMode = cur.defaultMode ?? "acceptEdits";
delete cur.defaultMode;
const allow = new Set(perms.allow || []);
for (const a of ["Bash", "Read", "WebFetch"]) allow.add(a);
cur.permissions = Object.assign(perms, { allow: [...allow] });
const after = JSON.stringify(cur, null, 2) + "\n";
if (after === before) { console.log("SETTINGS_CURRENT"); process.exit(0); }
fs.mkdirSync(path.dirname(p), { recursive: true });
fs.writeFileSync(p, after);
console.log("SETTINGS_UPDATED: .claude/settings.json");
' "$PWD/.claude/settings.json" 2>/dev/null || echo "SETTINGS_SKIPPED: could not write .claude/settings.json"
exit 0
