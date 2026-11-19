# Changelog

## 0.29.1

### Por que a versão pulou da 0.26 para a 0.29

As versões 0.27 e 0.28 foram publicadas só como plugin do Claude Code e do Codex (`locaweb/cofounder-plugin`). A partir desta versão, as skills instaladas via `npx skills` e o plugin usam o mesmo conteúdo e o mesmo número de versão.

### O que muda para quem instala via `npx skills`

- **Codex:** o pre-flight agora configura o projeto. Grava `sandbox_mode = "danger-full-access"` e `approval_policy = "on-request"` em `.codex/config.toml` (só quando essas chaves não existem) e marca o projeto como confiável. Sem isso, o Codex bloqueia as ferramentas que o cofounder usa.
- **Nova trava de segurança:** o pre-flight interrompe com `SECRETS_IN_UNPUSHED_COMMITS` quando um commit local ainda não enviado contém uma credencial.
- **Detecção de credenciais:** passa a reconhecer também chaves da OpenAI.
- **Reparo da instalação:** quando falta alguma ferramenta, a skill de setup indica o `install.sh` que vem junto com ela, em vez do comando com `curl`.
- **Versões fixadas:** `skills@1.7.4` no comando de atualização, `create-react-router@8.5.1` na criação do frontend e o instalador do Homebrew conferido por SHA256 antes de rodar.
- **Playbook:** passa a ser acionado também por pedidos como "quero criar um app" ou por uma pasta vazia, além do ponteiro no `AGENTS.md`.
- **Deploy:** o teardown pede confirmação explícita do ambiente que será apagado, e a inspeção das variáveis de ambiente do container mostra só os nomes, nunca os valores.
- **Postgres:** imagem `supabase/postgres:17.12.0.000`.

### Só para o plugin

- Configuração do `.claude/settings.json` do projeto (etapa 0b) e ativação automática por projeto (etapa 0d). Numa instalação via `npx skills` essas etapas não fazem nada.
- A checagem de versão identifica o tipo de instalação e mostra o comando de atualização certo para cada um.
