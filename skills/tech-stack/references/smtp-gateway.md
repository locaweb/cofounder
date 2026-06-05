# SMTP Gateway

An SMTP gateway is needed if the app sends e-mails (reminders, authentication links, etc.).

## Recommended methods

### Gmail SMTP — good for prototyping, low volume

#### 1. Generate an App Password

1. Go to <https://myaccount.google.com/security>
2. **Segurança e Login** → **Verificação em duas etapas** → ensure it is enabled
3. Type **"app passwords"** in the search field
4. Fill **Nome do app:** `SMTP`
5. The generated 16-character password is your SMTP app password

#### 2. Configure the web app

| Setting | Value |
|---------|-------|
| SMTP Server | `smtp.gmail.com` |
| Port | `587` (TLS/STARTTLS) |
| Username | Your full Gmail address |
| Password | The App Password generated above |

### Locaweb SMTP — good for production use

Sign up at <https://www.locaweb.com.br/smtp-locaweb/>. If you already have the SMTP service, go to **Central do Cliente** to retrieve your credentials.

**Important:** SMTP credentials are secrets. When entering them for local development, follow the "Entering secrets in `.env`" procedure in the tech-stack skill — the agent must never accept these values through the chat.

**Configure and test SMTP in the local development environment before deploying.** Gmail SMTP works from any network — verify that magic link emails are sent and received.
