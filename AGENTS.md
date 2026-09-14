# AGENTS.md — wsl-setup

Instruções para agentes (e humanos) trabalhando neste repositório.

Este instalador roda no computador de terceiros. Nada abaixo pode ser
assumido como já pronto. O **primeiro passo é sempre identificar o
ambiente**, antes de qualquer comando.

## O que é / o que não é

**É** o instalador público WSL2 Ubuntu da Oros: entrada Windows
(`Install-WslDevEnv.ps1`, menu pt-BR + flags) e bootstrap no guest
(`guest/bootstrap.sh`). Docs para humanos: `README.md`. Relato de
segurança: `SECURITY.md`.

**Não é** data-ingestion, nem um runtime de agentes, nem um gerenciador
de ciclo de vida do Herdr. Este instalador **não** inicia, para, reinicia
ou perfila o Herdr. **Não** instala firstmate nem outras ferramentas
privadas do captain por padrão.

### Fonte de verdade

| Artefato | Papel |
| --- | --- |
| `Install-WslDevEnv.ps1` | Comportamento no **host Windows** |
| `guest/bootstrap.sh` | Comportamento no **guest Ubuntu** |
| `guest/herdr-omarchy-keys.toml` | Template `[keys]` Omarchy (prefixo `ctrl+espaço`) |
| `README.md` | Como instalar (vários públicos) |
| Este arquivo | Regras para agentes |

Não invente flags. Leia o `.ps1` / `bootstrap.sh` / `README.md`.

## 0. Detectar o sistema operacional (obrigatório)

Cada lado deste repo só é válido num SO. Detecte **antes** de agir:

```bash
uname -s 2>/dev/null || echo "sem uname — provavelmente Windows nativo (cmd/PowerShell)"
printf 'WSL_DISTRO_NAME=%s WSL_INTEROP=%s\n' "${WSL_DISTRO_NAME-}" "${WSL_INTEROP-}"
```

- **Windows nativo** (sem `uname`, ou PowerShell com
  `[Environment]::OSVersion.Platform -eq 'Win32NT'` e **sem**
  `WSL_DISTRO_NAME` / `WSL_INTEROP`): host. Único lugar de onde se
  roda `Install-WslDevEnv.ps1`.
- **WSL** (`uname -s` = `Linux` **e** `WSL_DISTRO_NAME` ou
  `WSL_INTEROP` definidos): guest. Aqui só `guest/bootstrap.sh`.
  **Nunca** rode o `.ps1` de dentro do WSL (o script recusa, mas não
  tente contornar).
- **Linux/macOS sem WSL:** este instalador não se aplica. Não instale
  WSL, não rode o `.ps1`, não simule o guest com `curl | sh`.

Não assuma `pwsh`, `wsl.exe`, `docker`, `gh`, Node, Rust, Python, nem
que o operador é admin.

## Regras duras

- **Nunca** rode `Install-WslDevEnv.ps1` de dentro do WSL. No Windows:
  PowerShell **64-bit elevado** na primeira habilitação de recursos:
  `powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1`.
- **Nunca** faça `wsl --unregister` / `-ForceRecreate` sem o operador
  ter pedido **e** aceito perda de dados. Distro saudável permanece.
- **Nunca** crie conta Linux com senha vazia nem ligue NOPASSWD por
  padrão. `-PasswordlessSudo` / `--passwordless-sudo` é opt-in explícito.
- **Nunca** instale firstmate, CLIs fora da lista pedida, nem
  ferramentas privadas do captain.
- **Nunca** commite segredos: senhas reais, tokens, kubeconfigs,
  chaves privadas (`id_rsa*`, `id_ed25519`, `*.pem`), `.env` real,
  cópias de `state.json`. O `.gitignore` cobre os padrões comuns;
  não force add.
- **Nunca** copie chave SSH privada para o repositório, para
  `%LOCALAPPDATA%\wsl-dev-env\`, nem para logs. O guia GitHub gera
  `ed25519` em `~/.ssh` **no Ubuntu** e imprime **somente** a `.pub`.
  Cadastro: https://github.com/settings/keys — chave **pública** só.
- **Nunca** faça `curl | sh` / `irm | iex` para host que não está na
  lista de instaladores oficiais abaixo. Não “melhore” o bootstrap
  baixando de gist, CDN desconhecido ou fork. Pin/verifique URL quando
  for prático; senão recuse.
- **Não** inicie/pare/reinicie o Herdr daqui.
- Node é **fnm** + LTS (não nvm / NodeSource). PATH em
  `~/.config/wsl-dev-env/env.sh` via blocos marcados.
- Idioma: strings visíveis ao usuário em **pt-BR**; identificadores em
  inglês. Linux LF; PowerShell CRLF (`.gitattributes`).

## Flags (host → guest)

`--skip-base-dx --docker --gh --herdr --agents LIST --password-file --passwordless-sudo`.
Template Herdr: `guest/herdr-omarchy-keys.toml`.

Automação no host: `-NonInteractive` exige `-Username` (ou estado
salvo). Conta nova exige `-Password` (`SecureString`). Saída **3010** =
reboot necessário; reexecute o mesmo comando. Saída **1** = falha.
Detalhes no `README.md` (seção agente/automação).

## Idempotência e blocos marcados

Reexecuções são o caminho normal. Não concatene PATH, rc ou `[keys]`
do Herdr “para sempre”.

Marcadores (`guest/bootstrap.sh` / merge no Windows):

```
# --- wsl-dev-env begin:NOME ---
# --- wsl-dev-env end:NOME ---
```

Edite **dentro** do bloco, ou o gerador do bloco. Não espalhe duplicatas
em `.bashrc` / `.profile` / `config.toml`. `/etc/wsl.conf` preserva
chaves desconhecidas; só fixa `[user] default` e `[boot] systemd`.

## Instaladores oficiais (allowlist)

Os scripts só pipam curl/irm nestes hosts (e no apt/keyring do `gh`).
Não acrescente outro sem revisão humana explícita:

- `https://get.docker.com`
- `https://cli.github.com/packages/githubcli-archive-keyring.gpg`
- `https://sh.rustup.rs`
- `https://fnm.vercel.app/install`
- `https://starship.rs/install.sh`
- `https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh`
- `https://herdr.dev/install.sh` e `https://herdr.dev/install.ps1`
- `https://claude.ai/install.sh`
- `https://chatgpt.com/codex/install.sh`
- `https://opencode.ai/install`
- `https://x.ai/cli/install.sh`
- `https://code.kimi.com/kimi-code/install.sh`
- `https://cursor.com/install`
- npm `@earendil-works/pi-coding-agent` (equivalente ao `pi.dev/install.sh`, sem prompt no TTY)

## Testes sem sistemas de produção

Não precisa de Windows de produção, cluster, conta GitHub real nem
distro alheio.

- `bash -n guest/bootstrap.sh`
- parse do `.ps1` (CI: `.github/workflows/ci.yml`)
- ShellCheck com `--severity=warning` (infos SC2016 em heredoc são esperados)
- Releia flags e mensagens pt-BR; não execute o instalador “para ver”

Proibido em máquina de terceiros / CI: `-ForceRecreate`, unregister,
gravar senha em arquivo versionado, exfiltrar `~/.ssh/id_*`.

Se o operador já tem um Ubuntu WSL de **desenvolvimento** e pediu
reexecução: `-BootstrapOnly` / `guest/bootstrap.sh --user-only` são o
caminho seguro. Não recrie o distro.

## Padrões seguros em máquina de terceiros

DX base ligado; Docker, gh, Herdr, agentes, SSH e NOPASSWD **desligados**
até o operador marcar. Conta nova com senha informada. Distro existente
não é apagado. Estado em `%LOCALAPPDATA%\wsl-dev-env\state.json` (Windows)
não leva senha — apague se o operador não quiser persistir escolhas.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
