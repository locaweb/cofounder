---
description: Install the cofounder agent as the main thread for this project. This ensures the cofounder is always active in every session, managing your environment, requirements, and development workflow automatically.
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

   > **Este comando deve ser executado dentro de um diretório de projeto específico, não na pasta home.** Instalar o agente cofundador aqui o ativaria globalmente para todos os projetos. Por favor, entre no diretório do projeto que deseja configurar e tente novamente.

   Then stop — do not continue with the remaining steps.

2. Check if `.claude/settings.json` already exists in the project root.
   - If it exists, read it and check if it already has `"agent": "cofounder:cofounder"`. If so, tell the user it's already installed and skip to step 4.
   - If it exists but has different content, merge the `"agent"` key into the existing settings (preserve other keys).
   - If it doesn't exist, create the `.claude/` directory if needed.

3. Write `.claude/settings.json` with the agent setting:
   ```json
   {
     "agent": "cofounder:cofounder"
   }
   ```
   Make sure to preserve any existing keys if the file already existed.

4. Confirm to the user that the cofounder agent is now installed for this project:

   > O agente cofundador foi instalado. A configuração foi salva em `.claude/settings.json`, que pode ser commitado no git para que todos os colaboradores tenham a mesma experiência (eles precisam ter o plugin cofounder instalado também). Para remover depois, basta apagar a chave `"agent"` do `.claude/settings.json`.

5. Tell the user they need to start a new session for the agent to take effect. The cofounder agent becomes the main thread only in new sessions — it won't activate in the current one:

   > Inicie uma nova sessão clicando em **+ Nova sessão** na barra lateral

6. If the user responds back instead of starting a new session, launch the cofounder agent using the Agent tool with subagent_type set to "cofounder". Tell it to start a new session.
