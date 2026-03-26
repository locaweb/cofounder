# Quick Setup: Google Auth

## Create a Google Cloud project

1. Go to <https://cloud.google.com/>
2. Click **Comece a usar sem custo financeiro**
3. Sign up and choose a payment method: credit card (Google Auth is free — no charges)

## Configure the OAuth consent screen

1. Left navigation menu → **APIs e serviços** → **Credenciais**
2. Click **Configurar tela de consentimento** → **Vamos começar**
3. Choose a name for the app, select the pre-filled e-mail
4. Público: **Externo**
5. Contact info: your e-mail

## Create OAuth credentials

1. Left navigation menu → **Clientes** → **Criar cliente**
2. Application type: **Aplicativo da Web**
3. Under **URIs de redirecionamento autorizados** → **Adicionar URI** → paste the redirect URI provided by Claude
4. Click **Criar**
5. Copy the **ID do cliente** (Client ID) and **Chave secreta do cliente** (Client Secret)

**Important:** These credentials are secrets. When entering them for local development, follow the "Entering secrets in `.env`" procedure in the tech-stack skill — the agent must never accept these values through the chat.
