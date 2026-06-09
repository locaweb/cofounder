---
name: install
description: >
  This skill should be used when the user asks to "install the cofounder",
  "set up the cofounder in this project", "instalar o cofundador", or invokes
  `/cofounder:install`. It injects the cofounder instructions into the
  project's AGENTS.md (referenced from CLAUDE.md) and configures `.claude/settings.json`.
---

# Install Cofounder

Install the cofounder into the current project by injecting its instructions into AGENTS.md (with a reference from CLAUDE.md) and configuring project settings.

## Steps

1. **Safety check: refuse to install in the home directory.** Use the Bash tool to run `pwd` and compare it against `$HOME`. If the current working directory IS the user's home directory (e.g., `/Users/username` or `/home/username`), **do NOT proceed**. Instead, tell the user:

   > **Este comando deve ser executado dentro de um diretório de projeto específico, não na pasta home.** Instalar aqui ativaria o cofundador globalmente para todos os projetos. Por favor, entre no diretório do projeto que deseja configurar e tente novamente.

   Then stop — do not continue with the remaining steps.

2. **Inject cofounder instructions into AGENTS.md.** Run the injection script. It
   is bundled at `../../scripts/inject-agents-md.sh`, relative to the directory this
   `SKILL.md` lives in (a shared script at the plugin root, also used by the
   SessionStart hook). Locate it from the skill's own directory and run it,
   passing the project root as the only argument:
   ```bash
   bash <this-skill-dir>/../../scripts/inject-agents-md.sh "$(pwd)"
   ```
   This creates or updates `AGENTS.md` with the cofounder's managed section between `<!-- cofounder:begin -->` and `<!-- cofounder:end -->` markers, and adds a managed `@AGENTS.md` reference to `CLAUDE.md` so Claude (which does not read `AGENTS.md` natively) loads it.

3. **Configure `.claude/settings.json`.** Check if it already exists.
   - If it exists, read it and merge the keys below (preserve any other existing keys). **Remove the `"agent"` key if present** — it is no longer used.
   - If it doesn't exist, create the `.claude/` directory if needed.

   Write `.claude/settings.json` with:
   ```json
   {
     "defaultMode": "acceptEdits",
     "permissions": {
       "allow": ["Bash", "Read", "WebFetch"]
     }
   }
   ```

4. **Activate the cofounder instructions in this session.** Use the Read tool to read the just-updated `AGENTS.md` from the current working directory. This loads the cofounder's managed section into your context so you can act on it immediately, without requiring the user to restart.

5. **Proceed as if a new session just started.** Follow the Session Startup procedure defined in the AGENTS.md you just read — language detection, pre-flight check, and so on. Your first user-facing message after the install should be the cofounder's normal greeting in the user's language, not a "please restart" instruction.
