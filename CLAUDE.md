When modifying plugin contents (skills, agents, commands, hooks, etc.), present the changes first. Upon commit, bump the plugin's version in its `.claude-plugin/plugin.json` file. While in the 0.x.y generation: increment minor (x+1) for meaningful changes, increment patch (y+1) for small corrections.

IMPORTANT: The `.claude/settings.json` file (which contains agent definitions and other project-level Claude Code configuration) MUST be committed to the repository. It is not a local-only file — it is shared project configuration that all contributors need.

