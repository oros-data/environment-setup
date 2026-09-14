# wsl-setup

Bootstrap em PowerShell no Windows para um Ubuntu WSL2 enxuto, pronto para desenvolver.

**English:** Windows-side guided WSL2 Ubuntu installer. Prompts, menus, errors and this README are in **Brazilian Portuguese**. Run from elevated 64-bit Windows PowerShell:
`powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1`.
Audience sections below cover first install, flags (`-NonInteractive`, `-InstallDocker`, `-InstallHerdr`, `-Agents`, …), unattended exit codes (including **3010** reboot), and contributor rules.

Inspirado nos hábitos de CLI do [Omarchy](https://omarchy.org/) (starship + zoxide, sem desktop), agora com **instalação guiada**: você escolhe Docker, `gh`, Herdr (atalhos Omarchy), CLIs de agentes e o guia de SSH do GitHub. A senha da conta Linux é **definida na instalação**.

Este repositório é **só** o instalador WSL. Não é o monorepo data-ingestion, não instala firstmate e não liga ferramentas privadas do captain por padrão.

## Para quem é este repositório

| Público | Comece em |
| --- | --- |
| **Usuário final** (Windows, primeiro WSL) | [Avisos de segurança](#avisos-de-segurança-leia-antes) e [primeira instalação](#usuário-final--primeira-instalação-no-windows) |
| **Power user** (reexecução, flags) | [Power user](#power-user--reexecução-e-flags) |
| **Agente / automação** (unattended) | [Agente e automação](#agente-e-automação--unattended-e-códigos-de-saída) |
| **Contribuidor** | [Contribuidor](#contribuidor--como-alterar-scripts-com-segurança) e `AGENTS.md` |

## Avisos de segurança (leia antes)

- **PowerShell elevado.** A primeira execução que habilita recursos do Windows precisa de *Executar como administrador*. Isso altera o host. Não rode o `.ps1` se você não confia neste repositório.
- **Senha.** Conta Linux nova exige senha (digitação oculta). Ela **não** é gravada em `%LOCALAPPDATA%\wsl-dev-env\state.json`. Não coloque senha real em issues, PRs, logs, `.env` versionado nem na linha de comando em texto claro (`-Password` é `SecureString`).
- **Chaves SSH.** O guia mostra **somente a chave pública** (`.pub`) e abre https://github.com/settings/keys. **Nunca** cole, envie ou commite a chave **privada**. Os scripts não copiam `id_ed25519` / `id_rsa` para o repositório.
- **`-ForceRecreate` apaga o distro.** `wsl --unregister` destrói o sistema de arquivos da distro. Só use se você aceitar perder dados. Em `-NonInteractive` ainda exige `-Force`.
- **Docker.** O caminho principal é **Docker Engine dentro do Ubuntu (WSL2)**, não Docker Desktop. Não instale os dois ao mesmo tempo — eles brigam. Detalhes em [Docker](#docker-caminho-principal).
- **sudo sem senha** só com o item 7 / `-PasswordlessSudo`. Padrão: sudo **com** senha.
- **`curl \| sh`.** Os scripts só baixam instaladores oficiais da lista em `AGENTS.md`. Agentes **não** devem pipar curl para hosts desconhecidos.

## Layout

| Caminho | Papel |
| --- | --- |
| `Install-WslDevEnv.ps1` | Entrada no Windows (menu pt-BR + flags) |
| `guest/bootstrap.sh` | Bootstrap no Ubuntu (apt + toolchains + recursos) |
| `guest/herdr-omarchy-keys.toml` | Bloco `[keys]` Omarchy (prefixo `ctrl+espaço`) |
| `AGENTS.md` | Regras para agentes (detectar Windows vs WSL **antes** de agir) |
| `SECURITY.md` | Como relatar falhas; sem log de segredo |

## Pré-requisitos

- Windows 10 **64-bit** versão **1903** (build 18362) ou posterior, ou Windows 11. **2004+ / Win11** recomendado para existir `wsl --install`.
- Virtualização ligada no firmware (Intel VT-x / AMD-V / SVM).
- Se o próprio Windows for uma VM: **virtualização aninhada** ligada no hipervisor (Hyper-V `ExposeVirtualizationExtensions`, VMware “Virtualize Intel VT-x/AMD-V”, VirtualBox nested VT-x).
- PowerShell **64-bit** (não WOW64). A primeira execução que habilita recursos precisa de **Executar como administrador**.
- Internet no guest para rustup / fnm / starship / zoxide e para os instaladores oficiais que você escolher.
- Windows Terminal é agradável; não é obrigatório.

## Usuário final — primeira instalação no Windows

**Não** rode o `.ps1` de dentro do WSL. Se `$env:WSL_DISTRO_NAME` existir, você está no guest: saia e abra o PowerShell do Windows.

1. Copie este repositório para o disco do Windows (ou clone com Git for Windows).
2. Abra o **Windows PowerShell 64-bit como Administrador**.
3. Libere o script só neste processo e rode:

```powershell
cd caminho\para\wsl-setup
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1
```

Sem `-Username`, o script pergunta (oferece o login do Windows em minúsculas — nunca um nome aleatório). Em seguida mostra um **checklist numerado** (funciona no Windows PowerShell 5.1 elevado): DX base, Docker, gh, Herdr, agentes, GitHub/SSH, sudo sem senha.

Se a ExecutionPolicy bloquear o duplo-clique ou `.\Install-WslDevEnv.ps1`:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Install-WslDevEnv.ps1
```

Habilitar recursos do Windows costuma pedir **um reboot**. O script sai com **3010**, grava usuário + escolhas em `%LOCALAPPDATA%\wsl-dev-env\state.json` e imprime o comando para rodar de novo. **A senha não é gravada.** Depois do reboot, rode a mesma linha (não precisa continuar elevado se o WSL já funciona).

Depois:

```powershell
wsl -d Ubuntu -u SEUNOME
```

## O que o menu oferece

Padrão enxuto: **DX base ligado**, o resto desligado até você marcar.

| Recurso | Padrão | O que instala |
| --- | --- | --- |
| DX base (recomendado) | ligado | Python via apt; Node LTS via **fnm**; Rust via rustup; starship; zoxide; fzf; bash-completion |
| Docker | desligado | **Docker Engine no Ubuntu** (`https://get.docker.com`), usuário no grupo `docker`, systemd já ligado em `/etc/wsl.conf` |
| GitHub CLI (`gh`) | desligado | Pacote oficial no apt do guest |
| Herdr + atalhos Omarchy | desligado | Instalador oficial no Ubuntu (`https://herdr.dev/install.sh`) e, se possível, no Windows (`install.ps1`). Grava o `[keys]` de `guest/herdr-omarchy-keys.toml` sem apagar outras seções do `config.toml` |
| CLIs de agentes | nenhum | Só os que você marcar: **claude, codex, opencode, pi, grok, kimi, cursor** (instaladores oficiais) |
| GitHub + SSH | pergunta | Se você usa GitHub: gera `ed25519` em `~/.ssh` **no Ubuntu**, mostra a **chave pública**, abre https://github.com/settings/keys, instala `gh` se faltar, testa `ssh -T git@github.com` |
| sudo sem senha | desligado | Só se você ligar o item 7. Contas novas usam **sudo com senha** |

**firstmate** não é instalado (nem oferecido neste menu).

### Docker (caminho principal)

Para notebooks Win11 típicos este instalador usa **Docker Engine dentro do Ubuntu (WSL2)**, não o Docker Desktop. É scriptável, usa o `systemd=true` que já gravamos em `/etc/wsl.conf`, e não depende da GUI.

Depois do bootstrap, abra um **shell novo** (o grupo `docker` só vale no próximo login) e teste:

```bash
docker run --rm hello-world
```

Não instale Docker Desktop **por cima** deste engine (os dois brigam). Se você preferir Desktop: não marque Docker neste menu; instale à parte com `winget install Docker.DockerDesktop` e ligue a integração WSL2 na interface.

### gh

No guest, repositório apt oficial (`cli.github.com`). No Windows, se quiser o binário nativo: `winget install GitHub.cli`.

### Herdr + Omarchy

Instala o binário; **não inicia, não para e não recarrega** o Herdr. Os atalhos (prefixo `ctrl+espaço`, panes/tabs/workspaces no estilo tmux do Omarchy, tema tokyo-night se ainda não houver `[theme]`) vão para:

- Ubuntu: `~/.config/herdr/config.toml`
- Windows: `%APPDATA%\herdr\config.toml`

Reexecutar substitui só o bloco `[keys]` marcado (`# --- wsl-dev-env begin:herdr-keys ---`), sem limpar o resto.

### Agentes

Instaladores oficiais, só os escolhidos, idempotentes:

| id | CLI | Instalador |
| --- | --- | --- |
| `claude` | Claude Code | `https://claude.ai/install.sh` |
| `codex` | Codex CLI | `https://chatgpt.com/codex/install.sh` |
| `opencode` | OpenCode | `https://opencode.ai/install` |
| `pi` | Pi | pacote npm oficial `@earendil-works/pi-coding-agent` (mesmo do `https://pi.dev/install.sh`, sem prompt no TTY) |
| `grok` | Grok CLI | `https://x.ai/cli/install.sh` |
| `kimi` | Kimi Code CLI | `https://code.kimi.com/kimi-code/install.sh` |
| `cursor` | Cursor Agent | `https://cursor.com/install` |

### Senha

Conta **nova** exige senha (digitação oculta, com confirmação). Não criamos senha vazia nem `NOPASSWD` por padrão. `sudo` sem senha só com o item 7 / `-PasswordlessSudo`.

## Power user — reexecução e flags

Seguro reexecutar. Ferramentas já instaladas são puladas; apt é idempotente; blocos de rc e `[keys]` do Herdr são substituídos.

No Windows (host saudável, admin opcional):

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username SEUNOME
```

Dentro do Ubuntu:

```bash
sudo ./guest/bootstrap.sh --user SEUNOME --system-only   # opcional, apt
./guest/bootstrap.sh --user SEUNOME --user-only
# com os mesmos flags de recurso (--docker, --gh, --herdr, --agents …)
```

### Parâmetros

| Parâmetro | Significado |
| --- | --- |
| `-Username` | Conta Linux a criar ou reutilizar |
| `-Password` | `SecureString` da senha (obrigatório com `-NonInteractive` se a conta ainda não existe) |
| `-Distro Ubuntu` | Nome como em `wsl --list` (padrão `Ubuntu`) |
| `-BootstrapOnly` | Pula recursos / install do WSL; só roda `guest/bootstrap.sh` |
| `-SkipBootstrap` | Host + distro; não instala ferramentas do guest |
| `-ForceRecreate` | **Apaga** o distro e reinstala. Digite o nome para confirmar, ou passe `-Force` |
| `-Force` | Pula a confirmação de `-ForceRecreate` |
| `-NonInteractive` | Nunca pergunta; `-Username` obrigatório se não houver estado salvo |
| `-SkipBaseDx` | Não instala o DX base |
| `-InstallDocker` | Docker Engine no Ubuntu |
| `-InstallGh` | GitHub CLI no guest |
| `-InstallHerdr` | Herdr + atalhos Omarchy |
| `-Agents claude,pi` | Só estes agentes |
| `-SetupGitHubSsh` | Guia SSH (e instala `gh` se faltar) |
| `-PasswordlessSudo` | sudo sem senha (opt-in explícito) |

```powershell
$pwd = Read-Host 'Senha Linux' -AsSecureString
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -NonInteractive -Username SEUNOME -Password $pwd -InstallDocker -InstallGh -InstallHerdr -Agents claude,pi -SetupGitHubSsh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -BootstrapOnly -Username SEUNOME
```

### O que é instalado no host

- Recursos `Microsoft-Windows-Subsystem-Linux` e `VirtualMachinePlatform` (idempotente)
- WSL na versão **2**, `wsl --update` quando existir
- Distro **Ubuntu** atual se faltar (`wsl --install -d Ubuntu --no-launch` quando a flag existir)
- Herdr no Windows só se você pediu Herdr

### O que é instalado no guest (Ubuntu)

**Sempre (mínimo):** `curl`, `ca-certificates`, `git`, `sudo`, `locales` (`en_US` + `pt_BR`), `openssh-client`, `adduser`, `unzip`, `xz-utils`.

**DX base** (`apt-get install --no-install-recommends` + instaladores oficiais de usuário):

- `build-essential`, `bash-completion`, `fzf`, `jq`, `python3` + venv/pip/dev, `python-is-python3`
- Node LTS via **fnm** (um binário; sem repo NodeSource; sem blob do nvm no bashrc)
- Rust via rustup (`stable`, `--no-modify-path`)
- starship e zoxide em `~/.local/bin`

PATH fica em `~/.config/wsl-dev-env/env.sh`, sourced no `.profile` e no **topo** do `.bashrc` (antes do guard interativo do Ubuntu), para `wsl node` / `wsl cargo` funcionarem. Blocos marcados (`# --- wsl-dev-env begin:…`) são substituídos na reexecução, não concatenados para sempre.

`/etc/wsl.conf` define `default=<usuário>` e `systemd=true` sem apagar chaves desconhecidas.

## Agente e automação — unattended e códigos de saída

Detecte o SO **antes** de qualquer comando. Detalhes em `AGENTS.md`.

- **Nunca** rode `Install-WslDevEnv.ps1` de dentro do WSL (`WSL_DISTRO_NAME` / `WSL_INTEROP`).
- **Nunca** passe `-ForceRecreate` a menos que o operador peça explicitamente e aceite perda de dados.
- **Nunca** instale firstmate nem agentes além da lista pedida.
- **Nunca** faça `curl … \| sh` para host que não está na lista de instaladores oficiais.
- Senha: `Read-Host -AsSecureString` (ou equivalente); não escreva senha em arquivo versionado nem em log.

Exemplo unattended (PowerShell **Windows** 64-bit):

```powershell
$pwd = Read-Host 'Senha Linux' -AsSecureString
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -NonInteractive -Username SEUNOME -Password $pwd
```

| Código | Significado | O que o chamador faz |
| --- | --- | --- |
| **0** | Sucesso | Distro pronto; `wsl -d Ubuntu -u SEUNOME` |
| **1** | Falha | Leia o `ERRO:` no stderr/stdout; não repita às cegas com `-ForceRecreate` |
| **3010** | Sucesso, **precisa reboot** | Reinicie o Windows e rode **o mesmo comando**. Estado (usuário + flags) está em `%LOCALAPPDATA%\wsl-dev-env\state.json`; senha **não**. Se a conta ainda não existia, peça a senha de novo. |

`-NonInteractive` sem `-Username` (e sem estado salvo) falha. Conta nova sem `-Password` também falha. `-ForceRecreate` em `-NonInteractive` sem `-Force` é recusado.

Flags de host para o guest: `--skip-base-dx --docker --gh --herdr --agents LIST --password-file --passwordless-sudo`. Este instalador **não** inicia/para/reinicia o Herdr.

## Contribuidor — como alterar scripts com segurança

Fonte de verdade do comportamento: `Install-WslDevEnv.ps1` (host) e `guest/bootstrap.sh` (guest). Regras de idioma, quebras de linha, idempotência, segredos, allowlist de URLs e testes sem máquina de produção estão em `AGENTS.md` — leia antes de editar. Não trate este repositório como o monorepo data-ingestion.

CI (`.github/workflows/ci.yml`): ShellCheck com severidade warning + parse do PowerShell. Dependabot cobre só GitHub Actions.

## Notas de segurança (resumo operacional)

Ver [Avisos de segurança](#avisos-de-segurança-leia-antes) para as regras principais (senha, chaves SSH, `-ForceRecreate`, sudo sem senha, `curl | sh`). Complementos:

- Distro registrado mas quebrado falha com orientação; `-ForceRecreate` só se você aceitar perder dados.
- Relatar vulnerabilidades: `SECURITY.md` (aviso privado; não abra issue pública com exploit ou segredo).

## Solução de problemas

| Sintoma | O que fazer |
| --- | --- |
| Script recusa rodar dentro do WSL | Use o PowerShell **Windows** elevado |
| PowerShell 32-bit / `wsl.exe` sumiu | Use `Windows PowerShell` 64-bit (`$env:PROCESSOR_ARCHITECTURE` deve ser `AMD64` ou `ARM64`) |
| Virtualização desligada | Ligue VT-x/AMD-V no firmware |
| VM aninhada | Ligue nested virt no hipervisor, reinicie a VM |
| Recursos ligados, WSL morto | Reboot (saída 3010), rode de novo |
| `wsl --install` desconhecido | Atualize para Windows 10 2004+ / Windows 11 |
| Distro já existe | Padrão é manter + bootstrap. Apagar só com `-ForceRecreate` |
| `hypervisorlaunchtype Off` | Elevado: `bcdedit /set hypervisorlaunchtype Auto` e reboot |
| Docker: permission denied | Abra um shell WSL **novo** (grupo `docker`) |
| SSH GitHub falhou | Cadastre a `.pub` em https://github.com/settings/keys; nunca a chave privada |
