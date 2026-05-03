---
description: Instala o cofundador no projeto atual, injetando as instruções no CLAUDE.md e configurando o ambiente.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
---

Install the cofounder into the current project by injecting its instructions into CLAUDE.md and configuring project settings.

## Steps

1. **Safety check: refuse to install in the home directory.** Use the Bash tool to run `pwd` and compare it against `$HOME`. If the current working directory IS the user's home directory (e.g., `/Users/username` or `/home/username`), **do NOT proceed**. Instead, tell the user:

   > **Este comando deve ser executado dentro de um diretório de projeto específico, não na pasta home.** Instalar aqui ativaria o cofundador globalmente para todos os projetos. Por favor, entre no diretório do projeto que deseja configurar e tente novamente.

   Then stop — do not continue with the remaining steps.

2. **Inject cofounder instructions into CLAUDE.md.** Run the injection script:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/inject-claude-md.sh "$(pwd)" "${CLAUDE_PLUGIN_ROOT}"
   ```
   This creates or updates `CLAUDE.md` with the cofounder's managed section between `<!-- cofounder:begin -->` and `<!-- cofounder:end -->` markers.

3. **Configure `.claude/settings.json`.** Check if it already exists.
   - If it exists, read it and merge the keys below (preserve any other existing keys). **Remove the `"agent"` key if present** — it is no longer used.
   - If it doesn't exist, create the `.claude/` directory if needed.

   Write `.claude/settings.json` with:
   ```json
   {
     "model": "opus[1m]",
     "defaultMode": "acceptEdits",
     "permissions": {
       "allow": ["Bash", "Read", "WebFetch"]
     }
   }
   ```

4. Confirm to the user that the cofounder is now installed. Tell them to start a new session:

   > Cofundador instalado. Para começar a usar:
   > - **Claude Desktop:** clique em **+ Nova sessão** e descreva o que deseja construir.
   > - **Terminal (Claude Code CLI):** digite `/exit` para sair do Claude, e digite `claude` no terminal para reiniciar.

5. If the user responds back, remind them once that the cofounder instructions will only be active in new sessions, then continue the conversation normally.
