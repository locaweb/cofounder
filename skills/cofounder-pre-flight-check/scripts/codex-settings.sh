#!/usr/bin/env bash
# Codex only: the counterpart of claude-settings.sh. Codex starts an untrusted
# project read-only with no network, and its workspace-write sandbox still
# blocks every write outside the project (mise, Podman, gh, npm and Go caches),
# which the cofounder needs. So, like the Claude settings (Bash allowed), it:
#   - sets sandbox_mode = "danger-full-access" and approval_policy = "on-request"
#     in the project's .codex/config.toml, only when absent (a user's own choice
#     survives);
#   - marks the project trusted in <codex-home>/config.toml, without which Codex
#     ignores the project's .codex/config.toml. A project the user explicitly
#     marked untrusted is left alone.
# Codex keys both by the git root, so they are written there.
#
# Reads come first, so a session that is already configured never writes. The
# sandbox keeps .codex/ and the Codex home read-only; a blocked write is
# reported so the agent can run it again with escalated permissions.
#
# Always exits 0 (a failure must never block the session) and prints one of:
#   CODEX_SETTINGS_CURRENT
#   CODEX_SETTINGS_UPDATED: <files>
#   CODEX_SETTINGS_BLOCKED: <file>    (not writable from the sandbox; nothing changed)
#   CODEX_SETTINGS_UNTRUSTED          (the user marked the project untrusted; nothing changed)
#   CODEX_SETTINGS_SKIPPED: <reason>
set -uo pipefail

if [[ "$PWD" == "$HOME" ]]; then
    echo "CODEX_SETTINGS_SKIPPED: in the home directory"
    exit 0
fi

root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
project_cfg="$root/.codex/config.toml"
user_cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"

# The path goes into a TOML string and an awk -v value; keep both trivial.
case "$root" in
    *\"*|*\'*|*\\*)
        echo "CODEX_SETTINGS_SKIPPED: project path has quotes or backslashes"
        exit 0 ;;
esac

# Line-based TOML reading: enough for the forms Codex writes and the usual
# hand-edited variants (single or double quotes, spacing, trailing comment).
# Anything else about this project is reported as "other" and left untouched,
# because a duplicate key or table would make the whole file invalid.
AWK_LIB='
function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function is_root_header(line,   i, inner) {
    line = trim(line)
    if (substr(line, 1, 1) != "[" || substr(line, 1, 2) == "[[") return 0
    for (i = length(line); i > 0 && substr(line, i, 1) != "]"; i--) ;
    if (i == 0 || substr(line, i + 1) !~ /^[ \t]*(#.*)?$/) return 0
    inner = trim(substr(line, 2, i - 2))
    if (substr(inner, 1, 8) != "projects") return 0
    inner = trim(substr(inner, 9))
    if (substr(inner, 1, 1) != ".") return 0
    inner = trim(substr(inner, 2))
    return inner == "\"" root "\"" || inner == "\047" root "\047"
}
'

# Prints none | table:<trust_level value, empty when absent> | other.
scan_trust() {
    [[ -f "$user_cfg" ]] || { echo none; return; }
    awk -v root="$root" "$AWK_LIB"'
        { line = trim($0) }
        is_root_header($0) { if (found) dup = 1; found = 1; in_table = 1; next }
        substr(line, 1, 1) == "[" { in_table = 0 }
        index($0, "\"" root "\"") || index($0, "\047" root "\047") { other = 1; next }
        in_table && line ~ /^["\047]?trust_level["\047]?[ \t]*=/ {
            keys++
            v = line; sub(/^[^=]*=[ \t]*/, "", v)
            q = substr(v, 1, 1); val = "?"
            if (q == "\"" || q == "\047") { v = substr(v, 2); i = index(v, q); if (i) val = substr(v, 1, i - 1) }
        }
        END {
            if (other || dup || keys > 1) print "other"
            else if (!found) print "none"
            else print "table:" val
        }' "$user_cfg"
}

case "$(scan_trust)" in
    none) trust="" table=no ;;
    table:) trust="" table=yes ;;
    table:trusted) trust=trusted table=yes ;;
    table:untrusted)
        echo "CODEX_SETTINGS_UNTRUSTED"
        exit 0 ;;
    *)
        echo "CODEX_SETTINGS_SKIPPED: the Codex config has an entry for this project that this script does not edit"
        exit 0 ;;
esac

# Top-level keys are the lines before the first [table] header.
has_top_key() {
    [[ -f "$project_cfg" ]] && awk -v k="$1" '
        /^[[:space:]]*\[/ { exit 1 }
        $0 ~ "^[[:space:]]*[\"\047]?" k "[\"\047]?[[:space:]]*=" { found = 1; exit 0 }
        END { exit found ? 0 : 1 }' "$project_cfg"
}

add=""
has_top_key sandbox_mode || add+='sandbox_mode = "danger-full-access"'$'\n'
has_top_key approval_policy || add+='approval_policy = "on-request"'$'\n'

if [[ -z "$add" && "$trust" == "trusted" ]]; then
    echo "CODEX_SETTINGS_CURRENT"
    exit 0
fi

# write_file <dest> <content>: replace through a temp file in the same dir.
write_file() {
    local dir tmp
    dir="$(dirname "$1")"
    tmp="$dir/.cofounder-settings.$$"
    { mkdir -p "$dir" && printf '%s' "$2" >"$tmp" && mv "$tmp" "$1"; } 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null
    return 1
}

updated=()

if [[ -n "$add" ]]; then
    # Top-level keys must come before any table, so new ones go first.
    content="$add"
    [[ -f "$project_cfg" ]] && content+=$'\n'"$(cat "$project_cfg")"$'\n'
    if ! write_file "$project_cfg" "$content"; then
        echo "CODEX_SETTINGS_BLOCKED: $project_cfg"
        exit 0
    fi
    updated+=("${project_cfg#"$root"/}")
fi

if [[ "$trust" != "trusted" ]]; then
    if [[ "$table" == yes ]]; then
        # The table exists without trust_level: add it right after the header.
        content="$(awk -v root="$root" "$AWK_LIB"'
            { print }
            is_root_header($0) && !done { print "trust_level = \"trusted\""; done = 1 }' "$user_cfg")"$'\n'
    else
        content=""
        [[ -f "$user_cfg" ]] && content="$(cat "$user_cfg")"$'\n\n'
        content+="[projects.\"$root\"]"$'\n''trust_level = "trusted"'$'\n'
    fi
    if ! write_file "$user_cfg" "$content"; then
        echo "CODEX_SETTINGS_BLOCKED: $user_cfg"
        exit 0
    fi
    updated+=("$user_cfg")
fi

echo "CODEX_SETTINGS_UPDATED: ${updated[*]}"
exit 0
