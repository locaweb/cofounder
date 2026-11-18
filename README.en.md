# Marketplace

A plugin marketplace for [Claude Code](https://code.claude.com/docs/en/overview).

[Clique aqui para a versão em Português](README.md)

## Available plugins

| Plugin | Description |
|--------|-------------|
| [cofounder](skills/) | An AI-powered co-founder that guides you from idea to deployed web app. |

## Verifying the installation

Each version is published as a [GitHub Release](https://github.com/locaweb/cofounder/releases) with `install.sh`, a tarball of the `skills/` directory and a `SHA256SUMS` file. The artifacts carry provenance attestations proving they were built by the `release.yml` workflow from a specific commit of this repository. To verify them, use an authenticated [GitHub CLI](https://cli.github.com):

```bash
VERSION=v0.26.1
gh release download "$VERSION" --repo locaweb/cofounder --dir "cofounder-$VERSION"
cd "cofounder-$VERSION"
sha256sum -c SHA256SUMS   # on macOS: shasum -a 256 -c SHA256SUMS
gh attestation verify install.sh --repo locaweb/cofounder
gh attestation verify "cofounder-skills-$VERSION.tar.gz" --repo locaweb/cofounder
```

If everything passes, run the verified `install.sh` with `bash install.sh`.

## License

Functional Source License (FSL-1.1-ALv2) — see [LICENSE](LICENSE).
