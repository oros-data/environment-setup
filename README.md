# wsl-setup

Bootstrap em PowerShell no Windows para um Ubuntu WSL2 enxuto, pronto para desenvolver.

**English:** Windows-side guided WSL2 Ubuntu installer. Prompts, menus, errors and this README are in **Brazilian Portuguese**. Run from elevated 64-bit Windows PowerShell: `powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1`. See tables below for flags (`-NonInteractive`, `-InstallDocker`, `-InstallHerdr`, `-Agents`, …).

Inspirado nos hábitos de CLI do [Omarchy](https://omarchy.org/) (starship + zoxide, sem desktop), agora com **instalação guiada**: você escolhe Docker, `gh`, Herdr (atalhos Omarchy), CLIs de agentes e o guia de SSH do GitHub. A senha da conta Linux é **definida na instalação**.

## Layout

| Caminho | Papel |
| --- | --- |
| `Install-WslDevEnv.ps1` | Entrada no Windows (menu pt-BR + flags) |
| `guest/bootstrap.sh` | Bootstrap no Ubuntu (apt + toolchains + recursos) |
| `guest/herdr-omarchy-keys.toml` | Bloco `[keys]` Omarchy (prefixo `ctrl+espaço`) |

## Pré-requisitos

- Windows 10 **64-bit** versão **1903** (build 18362) ou posterior, ou Windows 11. **2004+ / Win11** recomendado para existir `wsl --install`.
- Virtualização ligada no firmware (Intel VT-x / AMD-V / SVM).
- Se o próprio Windows for uma VM: **virtualização aninhada** ligada no hipervisor (Hyper-V `ExposeVirtualizationExtensions`, VMware “Virtualize Intel VT-x/AMD-V”, VirtualBox nested VT-x).
- PowerShell **64-bit** (não WOW64). A primeira execução que habilita recursos precisa de **Executar como administrador**.
- Internet no guest para rustup / fnm / starship / zoxide e para os instaladores oficiais que você escolher.
- Windows Terminal é agradável; não é obrigatório.

## Como rodar (no Windows)

**Não** rode o `.ps1` de dentro do WSL.

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
| GitHub + SSH | pergunta | Se você usa GitHub: gera `ed25519`, mostra a **chave pública**, abre https://github.com/settings/keys, instala `gh` se faltar, testa `ssh -T git@github.com` |
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

## Parâmetros (automação)

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

## O que é instalado no host

- Recursos `Microsoft-Windows-Subsystem-Linux` e `VirtualMachinePlatform` (idempotente)
- WSL na versão **2**, `wsl --update` quando existir
- Distro **Ubuntu** atual se faltar (`wsl --install -d Ubuntu --no-launch` quando a flag existir)
- Herdr no Windows só se você pediu Herdr

## O que é instalado no guest (Ubuntu)

**Sempre (mínimo):** `curl`, `ca-certificates`, `git`, `sudo`, `locales` (`en_US` + `pt_BR`), `openssh-client`, `adduser`, `unzip`, `xz-utils`.

**DX base** (`apt-get install --no-install-recommends` + instaladores oficiais de usuário):

- `build-essential`, `bash-completion`, `fzf`, `jq`, `python3` + venv/pip/dev, `python-is-python3`
- Node LTS via **fnm** (um binário; sem repo NodeSource; sem blob do nvm no bashrc)
- Rust via rustup (`stable`, `--no-modify-path`)
- starship e zoxide em `~/.local/bin`

PATH fica em `~/.config/wsl-dev-env/env.sh`, sourced no `.profile` e no **topo** do `.bashrc` (antes do guard interativo do Ubuntu), para `wsl node` / `wsl cargo` funcionarem. Blocos marcados (`# --- wsl-dev-env begin:…`) são substituídos na reexecução, não concatenados para sempre.

`/etc/wsl.conf` define `default=<usuário>` e `systemd=true` sem apagar chaves desconhecidas.

## Reexecução

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

## Notas de segurança

- Distro **saudável** existente permanece. O script **não** faz `wsl --unregister` sem **`-ForceRecreate`**.
- Distro registrado mas quebrado falha com orientação; `-ForceRecreate` só se você aceitar perder dados.
- Sem segredos na nuvem. A chave **privada** SSH nunca é exibida nem enviada; só a `.pub`.
- Usuário + escolhas de recurso ficam em `%LOCALAPPDATA%\wsl-dev-env\state.json` para o reboot. Apague o arquivo se não quiser. **Senha não entra aí.**
- Conta nova nasce com senha que você digitou e sudo **com** senha, salvo opt-in de NOPASSWD.

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
