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

1. Check if `.claude/settings.json` already exists in the project root.
   - If it exists, read it and check if it already has `"agent": "cofounder:cofounder"`. If so, tell the user it's already installed and skip to step 3.
   - If it exists but has different content, merge the `"agent"` key into the existing settings (preserve other keys).
   - If it doesn't exist, create the `.claude/` directory if needed.

2. Write `.claude/settings.json` with the agent setting:
   ```json
   {
     "agent": "cofounder:cofounder"
   }
   ```
   Make sure to preserve any existing keys if the file already existed.

3. Confirm to the user that the cofounder agent is now installed for this project. Explain briefly (in both English and Portuguese):
   - The setting is saved in `.claude/settings.json` which can be committed to git so all collaborators get the same experience (they need the cofounder plugin installed too).
   - To remove it later, they can delete the `"agent"` key from `.claude/settings.json`.

4. Tell the user they need to start a new session for the agent to take effect. The cofounder agent becomes the main thread only in new sessions — it won't activate in the current one. Since we haven't asked the user's preferred language yet, give the instruction in both English and Portuguese:

   > Inicie uma nova sessão clicando em **+ Nova sessão** na barra lateral
   >
   > Start a new session by clicking on **+ New session** in the sidebar

5. If the user responds back instead of starting a new session, launch the cofounder agent using the Agent tool with subagent_type set to "cofounder". Tell it to start a new session.
