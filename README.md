<p align="center">
  <img src="https://raw.githubusercontent.com/locaweb/cofounder-plugin/e05efd3f3190f56d79fb018a4f444e7a0847c38c/shared/brand/icon-512.png" alt="cofounder" width="128" height="128">
</p>

# cofounder

Um cofundador movido por IA que guia você da ideia ao app publicado na internet, sem precisar saber programar.

[Click here for the English version](README.en.md)

![cofounder em ação](demo.webp)

## O que ele faz

O cofounder é um conjunto de [skills](skills/) para o seu agente de programação (Claude Code, Codex, Cursor, Gemini, OpenCode e outros). Ele conversa com você em linguagem simples, escreve com você a especificação do produto, desenvolve o app, testa e publica na Locaweb Cloud.

Este repositório é onde as skills são desenvolvidas. Há duas formas de instalar:

- **Via `npx skills`**, com o `install.sh` deste repositório: funciona com qualquer agente compatível e está descrita abaixo.
- **Como plugin do Claude Code ou do Codex**: veja o [locaweb/cofounder-plugin](https://github.com/locaweb/cofounder-plugin). O plugin traz as mesmas skills, na mesma versão.

## Instalação

Abra um terminal na pasta onde você quer criar o projeto e rode:

```bash
/bin/bash -c "$(curl -fsSL https://cofounder.locaweb.com.br/install.sh)"
```

Se preferir conferir o script antes de rodar, baixe o `install.sh` da [última Release](https://github.com/locaweb/cofounder/releases/latest), verifique como explicado em [Verificando uma versão](#verificando-uma-versão) e rode `bash install.sh`.

O script pode ser rodado mais de uma vez sem problema e:

- instala as ferramentas de desenvolvimento (mise, Podman, GitHub CLI e outras);
- instala as skills do cofounder no projeto via [`npx skills`](https://github.com/vercel-labs/skills);
- configura o seu agente para carregar o cofounder no início de cada sessão (`AGENTS.md` e `CLAUDE.md`, e `.claude/settings.json` quando o Claude Code está instalado).

Depois, abra o seu agente na mesma pasta (por exemplo, rode `claude`) e diga oi.

Se o script é rodado na sua pasta pessoal (`$HOME`), ele só instala as ferramentas e não mexe em nenhum projeto.

### Atualizando

No início de cada sessão, o cofounder confere se existe uma versão nova e, se houver, mostra o comando de atualização. Para atualizar à mão, rode na pasta do projeto:

```bash
mise x node@22 -- npx -y skills@1.7.4 add locaweb/cofounder --agent universal claude-code hermes-agent --skill '*' -y
```

O que muda em cada versão está no [CHANGELOG](CHANGELOG.md).

## Exemplos de uso

- **"Tenho uma ideia de app"**: o cofounder faz perguntas, escreve um PRD e propõe a primeira versão.
- **"Rode o app no meu computador"**: sobe o banco, o backend e o frontend localmente para você testar.
- **"Crie uma página de login" / "corrija este erro"**: implementa a mudança com testes automatizados e confere o resultado visualmente.
- **"Coloque na internet"**: cria o repositório no GitHub e os ambientes de preview e de produção, e publica na Locaweb Cloud.
- **"Use meu próprio domínio"**: configura um domínio personalizado no ambiente de produção.

## Segurança

As skills são **arquivos estáticos instalados localmente** no seu projeto: instruções em Markdown e scripts shell que você pode ler antes de usar. Elas não baixam nem executam código remoto não autorizado. Todo comando roda na sua máquina, pelo seu agente e com a sua permissão. As ferramentas instaladas pelo `install.sh` vêm das fontes oficiais, com versões fixadas e checksums ou chaves de assinatura verificados.

### Verificando uma versão

Cada versão é publicada como um [GitHub Release](https://github.com/locaweb/cofounder/releases) com o `install.sh`, um tarball do diretório `skills/` e um `SHA256SUMS`. Os artefatos têm attestation de proveniência que prova que foram gerados pelo workflow `release.yml` a partir de um commit específico deste repositório. Para verificar, use o [GitHub CLI](https://cli.github.com) autenticado:

```bash
VERSION=v0.29.1
gh release download "$VERSION" --repo locaweb/cofounder --dir "cofounder-$VERSION"
cd "cofounder-$VERSION"
sha256sum -c SHA256SUMS   # no macOS: shasum -a 256 -c SHA256SUMS
gh attestation verify install.sh --repo locaweb/cofounder
gh attestation verify "cofounder-skills-$VERSION.tar.gz" --repo locaweb/cofounder
```

Se tudo passar, rode o `install.sh` verificado com `bash install.sh`.

## Desenvolvimento

- **Skills:** cada pasta em [`skills/`](skills/) é uma skill (`cofounder-<nome>`), com o `SKILL.md` e, quando precisa, scripts e referências.
- **Testes:** `bash tests/scripts/test-scripts.sh` roda os testes dos scripts. Os outros níveis (instalação em container, macOS, agente com juiz) estão em [`tests/README.md`](tests/README.md).
- **Versão:** toda mudança nas skills sobe a versão em `.claude-plugin/plugin.json`, roda `scripts/stamp-version.sh` e ganha uma entrada no [CHANGELOG](CHANGELOG.md). Mudanças só em documentação, como este README, não geram versão.
- **Release:** depois do merge do PR, `scripts/tag-github-release.sh` cria a tag `v<versão>`, que publica a Release. O [locaweb/cofounder-plugin](https://github.com/locaweb/cofounder-plugin) copia as skills de cada tag nova.

## Licença

Functional Source License (FSL-1.1-ALv2) — veja [LICENSE](LICENSE).
