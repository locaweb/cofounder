#!/usr/bin/env bash
# Plugin installs only (Claude Code and Codex): writes the activation pointer
# into the project's AGENTS.md (+ a CLAUDE.md @import, since Claude Code doesn't
# read AGENTS.md natively), so the cofounder starts on its own in every later
# session of this project. It replaces the SessionStart hook, which the Claude
# plugin directory only accepts from Verified organizations: the user starts
# the cofounder once per project (/cofounder:iniciar), and from then on the project's
# own instructions file activates it.
#
# Same scope as the old hook: it only writes in an empty folder (a new project)
# or in a folder that already is a cofounder project (it has the docs the
# cofounder writes), and stays out of projects that have the `npx skills`
# install, whose own pointer install.sh writes. install.sh writes this same
# plugin pointer (PLUGIN_POINTER there) when it detects the plugin; keep the two
# in sync, including the managed-block markers.
#
# Always exits 0 (a failure must never block the session) and prints one of:
#   ACTIVATION_CURRENT
#   ACTIVATION_UPDATED: <files>
#   ACTIVATION_BLOCKED: <file>     (not writable, e.g. Codex read-only sandbox; nothing changed)
#   ACTIVATION_SKIPPED: <reason>
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Same plugin detection as version-check.sh: a plugin root above the skill.
# Codex plugins are copies of the same repo, so they match too.
if [[ ! -f "$here/../../../.claude-plugin/plugin.json" ]]; then
    echo "ACTIVATION_SKIPPED: not a plugin install (install.sh writes the pointer)"
    exit 0
fi
project="$PWD"
if [[ "$project" == "$HOME" ]]; then
    echo "ACTIVATION_SKIPPED: in the home directory"
    exit 0
fi
if [[ -f "$project/.claude/skills/cofounder-playbook/SKILL.md" || -f "$project/.agents/skills/cofounder-playbook/SKILL.md" ]]; then
    echo "ACTIVATION_SKIPPED: npx skills install present"
    exit 0
fi

is_cofounder_project() {
    [[ -f "$project/docs/PRD.md" || -f "$project/docs/INFRASTRUCTURE.md" ]] && return 0
    local item
    for item in "$project"/* "$project"/.[!.]* "$project"/..?*; do
        [[ -e "$item" ]] || continue
        # Same exempt entries as preflight.sh's existing-content guard.
        case "${item##*/}" in
            .git|.claude|.agents|.codex|.hermes|.venv|CLAUDE.md|AGENTS.md|.gitignore|skills-lock.json) continue ;;
        esac
        return 1
    done
    return 0
}
if ! is_cofounder_project; then
    echo "ACTIVATION_SKIPPED: not a cofounder project yet"
    exit 0
fi

BEGIN_MARKER="<!-- cofounder:begin -->"
END_MARKER="<!-- cofounder:end -->"
PLUGIN_POINTER="You are operating as a cofounder. Your FIRST action this session — before responding to or acting on the user's message, even if it is a specific task, question, or feature request — MUST be to load the \`cofounder-playbook\` skill of the cofounder plugin (in Claude Code, use the Skill tool to invoke \`cofounder:cofounder-playbook\`; in other agents, invoke it by the name their skills listing shows), then follow it as your operating instructions for the entire session. Do not begin the user's request until the playbook is loaded. (If the cofounder plugin is not installed, tell the user to install it as described in https://github.com/locaweb/cofounder-plugin and to start a new session.)"
CLAUDE_IMPORT="The cofounder operating instructions are maintained in @AGENTS.md — read and follow them."

# A begin marker without its end marker would make render() drop everything
# after it (the user's own content) and never write the block. Leave both files
# alone; closing the block is the user's call. Checked before any write, so a
# run never updates one file and stops at the other.
for name in AGENTS.md CLAUDE.md; do
    file="$project/$name"
    if [[ -f "$file" ]] && grep -q '<!-- cofounder:begin' "$file" && ! grep -q '<!-- cofounder:end -->' "$file"; then
        echo "ACTIVATION_SKIPPED: unclosed cofounder block in $name"
        exit 0
    fi
done

# render <file> <body> — print the file's content with the managed block set to
# <body>: replaced in place, appended, or as a new file.
render() {
    local file="$1" block="$BEGIN_MARKER"$'\n'"$2"$'\n'"$END_MARKER"
    if [[ ! -f "$file" ]]; then
        printf '%s\n' "$block"
    elif grep -q '<!-- cofounder:begin' "$file"; then
        BLOCK="$block" awk '
            /<!-- cofounder:begin/ { skip = 1 }
            skip && /<!-- cofounder:end -->/ { print ENVIRON["BLOCK"]; skip = 0; next }
            !skip { print }
        ' "$file"
    else
        cat "$file"
        printf '\n%s\n' "$block"
    fi
}

# write_file <dest> <content>: replace through a temp file in the same dir.
write_file() {
    local tmp
    tmp="$(dirname "$1")/.cofounder-activation.$$"
    { printf '%s' "$2" >"$tmp" && mv "$tmp" "$1"; } 2>/dev/null && return 0
    rm -f "$tmp" 2>/dev/null
    return 1
}

updated=()
for pair in "AGENTS.md:$PLUGIN_POINTER" "CLAUDE.md:$CLAUDE_IMPORT"; do
    name="${pair%%:*}"
    file="$project/$name"
    # $(...) drops trailing newlines; add the one every rendered file ends with.
    content="$(render "$file" "${pair#*:}")"$'\n'
    [[ -f "$file" && "$content" == "$(cat "$file")"$'\n' ]] && continue
    if ! write_file "$file" "$content"; then
        echo "ACTIVATION_BLOCKED: $file"
        exit 0
    fi
    updated+=("$name")
done

if [[ ${#updated[@]} -eq 0 ]]; then
    echo "ACTIVATION_CURRENT"
else
    echo "ACTIVATION_UPDATED: ${updated[*]}"
fi
exit 0
