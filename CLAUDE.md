When modifying plugin contents (skills, agents, commands, hooks, etc.), present the changes first. Upon commit, bump the plugin's version in its `.claude-plugin/plugin.json` file. While in the 0.x.y generation: increment minor (x+1) for meaningful changes, increment patch (y+1) for small corrections.

After bumping the version in `plugin.json`, run `scripts/stamp-version.sh` to propagate it to the `COFOUNDER_VERSION` marker in `skills/pre-flight-check/SKILL.md`.

## Legacy version-check shim

`plugins/cofounder/.claude-plugin/plugin.json` is a compatibility shim, not leftover cruft — do **not** delete it casually. Clients installed before the root-level restructure (cofounder `<= 0.21.10`) run a pre-flight version check that fetches the manifest from this old path; without the shim they 404 and never learn an update exists. `scripts/stamp-version.sh` keeps it mirrored to the canonical `.claude-plugin/plugin.json`. Remove it only once pre-`0.21.11` clients are no longer in the wild.

IMPORTANT: The `.claude/settings.json` file (which contains agent definitions and other project-level Claude Code configuration) MUST be committed to the repository. It is not a local-only file — it is shared project configuration that all contributors need.

## install.sh redirect

The computer-setup installer lives at `skills/computer-setup/scripts/install.sh` in this repo. The cofounder-site app (`~/cofounder-site`, deployed at `cofounder.giba.tech`) serves a 302 redirect from `https://cofounder.giba.tech/install.sh` to the raw GitHub URL of this file. When changing the script's path or filename, update the redirect target in the cofounder-site Go backend (`backend/cmd/server/main.go`) to match.

