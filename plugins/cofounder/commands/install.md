---
description: Instala o agente cofounder como a thread principal deste projeto. Isso garante que o cofounder esteja sempre ativo em cada sessão, gerenciando o fluxo de desenvolvimento automaticamente.
allowed-tools:
  - Bash
  - Read
  - Write
  - Edit
  - Glob
  - Agent
---

Install the cofounder agent into the current project so it runs automatically on every session.

## Steps

1. **Safety check: refuse to install in the home directory.** Use the Bash tool to run `pwd` and compare it against `$HOME`. If the current working directory IS the user's home directory (e.g., `/Users/username` or `/home/username`), **do NOT proceed**. Instead, tell the user:

   > **Este comando deve ser executado dentro de um diretório de projeto específico, não na pasta home.** Instalar o agente aqui o ativaria globalmente para todos os projetos. Por favor, entre no diretório do projeto que deseja configurar e tente novamente.

   Then stop — do not continue with the remaining steps.

2. Check if `.claude/settings.json` already exists in the project root.
   - If it exists, read it and check if it already has `"agent": "cofounder:cofounder"`, `"defaultMode": "acceptEdits"`, and the permissions allow list below. If all are present, tell the user it's already installed and skip to step 4.
   - If it exists but is missing some of those keys, merge them in (preserve any other existing keys).
   - If it doesn't exist, create the `.claude/` directory if needed.

3. Write `.claude/settings.json` with the following settings:
   ```json
   {
     "agent": "cofounder:cofounder",
     "defaultMode": "acceptEdits",
     "permissions": {
       "allow": ["Bash", "Read", "WebFetch"]
     }
   }
   ```
   Make sure to preserve any existing keys if the file already existed.

4. Confirm to the user that the cofounder agent is now installed. Tell them to start a new session to begin using it:

   > Agente instalado. Para começar a usar:
   > - **Claude Desktop:** clique em **+ Nova sessão** e descreva o que deseja construir.
   > - **Terminal (Claude Code CLI):** digite `/exit` para sair do Claude, e reinicie o terminal para voltar ao Claude.

5. If the user responds back, remind them once that the cofounder agent will only be active in new sessions, then continue the conversation normally.
