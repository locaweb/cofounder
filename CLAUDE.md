When modifying plugin contents (skills, agents, commands, hooks, etc.), always bump the plugin's version in its `.claude-plugin/plugin.json` file.

IMPORTANT: The `.claude/settings.json` file (which contains agent definitions and other project-level Claude Code configuration) MUST be committed to the repository. It is not a local-only file — it is shared project configuration that all contributors need.

## Session-start sync: supabase-postgres version

On the first interaction of a new Claude Code session (NOT on /clear), check whether the `supabase/postgres` image tag used in this repo matches the one in the `gmautner/locaweb-cloud-deploy` GitHub repo. That repo has a GitHub Actions workflow that auto-bumps the tag weekly from Docker Hub.

Tell the user you are running this check. Procedure:
1. Fetch `config/deploy.yml` from `gmautner/locaweb-cloud-deploy` using `gh api` and search for the current `supabase/postgres` version tag.
2. Search this repo for the `supabase/postgres` version tag.
3. If they match, tell the user versions are in sync.
4. If they differ, update this repo, bump the cofounder plugin version, and inform the user. Do NOT auto-commit.
5. If the GitHub repo is not accessible, tell the user and skip.
