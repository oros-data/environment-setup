# Segurança

**English:** Report vulnerabilities **privately**. Do not open a public issue
with an exploit, a private key, a password, or a token. Use GitHub Security
Advisories on this repository. This installer must never log or commit secrets.

## Relatar problemas

Este repositório é um **instalador** que roda elevado no Windows e como root
no Ubuntu. Falhas aqui afetam máquinas de terceiros.

1. Use **GitHub Security Advisories** neste repo (Security → Report a vulnerability),
   ou avise um maintainer da org `oros-data` por canal privado.
2. **Não** abra issue pública com PoC, payload, senha, chave privada, kubeconfig
   ou token.
3. Inclua: versão/`commit` do instalador, host (Win10/11, build), distro, se
   rodou elevado, e o que aconteceu — **sem** colar segredos.

Não há artefatos versionados além de `main`. Trate `main` como a linha suportada.

## O que este instalador não deve fazer

- **Não** gravar senha em `%LOCALAPPDATA%\wsl-dev-env\state.json`, no git, em
  log, nem em issue/PR.
- **Não** exfiltrar chave SSH **privada**. O guia GitHub gera `ed25519` em
  `~/.ssh` no Ubuntu e mostra **somente** a `.pub` (cadastro em
  https://github.com/settings/keys).
- **Não** copiar `id_rsa*`, `id_ed25519`, `*.pem` ou kubeconfig para o
  repositório (nem “de exemplo”).
- **Não** pipar `curl | sh` / `irm | iex` para host fora da allowlist em
  `AGENTS.md`.
- **Não** desregistrar distro saudável sem `-ForceRecreate` confirmado.
- **Não** criar conta com senha vazia nem `NOPASSWD` sem opt-in.

Se um PR ou log vazar segredo: revogue o credencial, rode `git filter` /
rotação conforme o caso, e avise em privado — não republicar o valor.

## Escopo

Relatos úteis: execução elevada inesperada, vazamento de senha/chave,
`curl | sh` para destino não listado, `-ForceRecreate` sem confirmação,
log de `SecureString` em texto claro.

Fora de escopo típico: “WSL da Microsoft tem bug”, falha de um instalador
oficial de terceiro (Docker, rustup, CLIs de agentes) **sem** o nosso
script ter mudado a URL.
