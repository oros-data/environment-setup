# wsl-setup

Windows-side PowerShell bootstrap for a lean, developer-ready WSL2 Ubuntu environment.

Inspired by [Omarchy](https://omarchy.org/) CLI habits (starship + zoxide, no desktop stack) without packing a kitchen sink. Primary story: a **clean Windows 10 1903+ / Windows 11** machine.

Captain-private tools (firstmate, Claude, Grok, …) are **not** installed. See [Optional extras](#optional-extras-not-installed).

## Layout

| Path | Role |
| --- | --- |
| `Install-WslDevEnv.ps1` | Windows host entrypoint |
| `guest/bootstrap.sh` | Ubuntu guest bootstrap (apt + toolchains + shell rc) |

## Prerequisites

- 64-bit Windows 10 version **1903** (build 18362) or later, or Windows 11. **2004+ / Win11** recommended so `wsl --install` exists.
- Firmware virtualization enabled (Intel VT-x / AMD-V / SVM).
- If Windows itself is a VM: **nested virtualization** must be on (Hyper-V `ExposeVirtualizationExtensions`, VMware “Virtualize Intel VT-x/AMD-V”, VirtualBox nested VT-x).
- 64-bit PowerShell (not WOW64). First run that enables features needs **Run as administrator**.
- Internet on the guest for rustup / fnm / starship / zoxide.
- Windows Terminal is nice to have; not required.

## Run (from Windows)

Do **not** run the `.ps1` from inside WSL.

1. Copy this repo onto the Windows filesystem (or clone it from Git for Windows).
2. Open **64-bit Windows PowerShell as Administrator**.
3. Allow the local script for this process only, then run it:

```powershell
cd path\to\wsl-setup
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username YOURNAME
```

If ExecutionPolicy blocks a double-click or `.\Install-WslDevEnv.ps1`:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Install-WslDevEnv.ps1 -Username YOURNAME
```

Omit `-Username` and the script prompts (offers your Windows login, lowercased — never a random name).

Enabling Windows features often needs **one reboot**. The script exits **3010**, saves the username under `%LOCALAPPDATA%\wsl-dev-env\state.json`, and prints the re-run command. After reboot, run the same line again (no need to stay elevated if WSL already works).

Then:

```powershell
wsl -d Ubuntu -u YOURNAME
```

## Parameters

| Parameter | Meaning |
| --- | --- |
| `-Username` | Linux account to create or reuse |
| `-Distro Ubuntu` | Distro name as in `wsl --list` (default `Ubuntu`) |
| `-BootstrapOnly` | Skip feature enable / WSL install; only run `guest/bootstrap.sh` |
| `-SkipBootstrap` | Host + distro + user only; do not install guest tools |
| `-ForceRecreate` | **Deletes** the distro and reinstalls. Type the distro name to confirm, or pass `-Force` |
| `-Force` | Skip the `-ForceRecreate` confirmation |
| `-NonInteractive` | Never prompt; `-Username` required unless a saved state exists |

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -BootstrapOnly -Username YOURNAME
```

## What gets installed

**Windows host**

- Features `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` (idempotent)
- WSL default version **2**, `wsl --update` when available
- Current **Ubuntu** distro if missing (`wsl --install -d Ubuntu --no-launch` when the flag exists)

**Guest (Ubuntu)** — `apt-get install --no-install-recommends`

- Base: `build-essential`, `curl`, `ca-certificates`, `git`, `jq`, `unzip`, `xz-utils`, `bash-completion`, `locales`, `sudo`
- Python: `python3`, `python3-pip`, `python3-venv`, `python3-dev`, `python-is-python3`
- `fzf` (small; key-bindings + completion)

**Guest (user-space, official installers)**

| Tool | How | Why |
| --- | --- | --- |
| Node LTS | **fnm** then `fnm install --lts` | One small binary; no NodeSource apt repo; no nvm bashrc blob |
| Rust | rustup (`stable`, `--no-modify-path`) | Official |
| starship | official `install.sh` → `~/.local/bin` | Omarchy-style prompt |
| zoxide | official `install.sh` → `~/.local/bin` | Omarchy-style jumper |

PATH is kept in `~/.config/wsl-dev-env/env.sh` and sourced from `.profile` plus the **top** of `.bashrc` (ahead of Ubuntu’s interactive guard) so `wsl node` / `wsl cargo` work. Marked blocks (`# --- wsl-dev-env begin:…`) are replaced on re-run, not appended forever.

A new Linux user is created with **no password** and passwordless sudo so the first run is non-interactive. Existing users are not given a new sudoers drop-in. `/etc/wsl.conf` sets `default=<user>` and `systemd=true` without wiping unknown keys.

Not installed: Docker, desktops, Neovim, tmux, snap, NodeSource, nvm, oh-my-bash, extra “modern unix” clones.

## Re-run

Safe to re-run. Installed tools are skipped; apt is idempotent; shell rc blocks are replaced.

From Windows (after the host is healthy, admin is optional):

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username YOURNAME
```

From inside Ubuntu:

```bash
sudo ./guest/bootstrap.sh --user YOURNAME --system-only   # optional apt refresh
./guest/bootstrap.sh --user YOURNAME --user-only
# or, as YOURNAME with passwordless sudo:
./guest/bootstrap.sh
```

## Safety notes

- An existing **healthy** distro is left alone. The script will not `wsl --unregister` unless you pass **`-ForceRecreate`**.
- A registered but broken distro fails with guidance; use `-ForceRecreate` only if you accept data loss.
- No cloud secrets, SSH keys, or git `user.name` / `user.email` are written.
- Username is stored in `%LOCALAPPDATA%\wsl-dev-env\state.json` so a post-reboot re-run can skip the prompt. Delete that file if you do not want it.
- This is a personal **dev box** setup (empty password + NOPASSWD for accounts the script creates). Run `passwd` and tighten `/etc/sudoers.d/90-wsl-dev-env-*` if the machine is shared.

## Optional extras (not installed)

Add these yourself if you want them; they are intentionally out of the default path:

- GitHub CLI (`gh`), ripgrep, fd, bat, direnv, pipx, Docker Desktop / docker-ce
- Agent CLIs (firstmate, Claude, Grok, Codex, …)
- A Nerd Font in Windows Terminal if you want starship icons

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Script refuses to run inside WSL | Use elevated **Windows** PowerShell |
| 32-bit PowerShell / `wsl.exe` missing | Use 64-bit `Windows PowerShell` (`$env:PROCESSOR_ARCHITECTURE` should be `AMD64` or `ARM64`) |
| Virtualization disabled | Enable VT-x/AMD-V in firmware |
| Nested VM | Enable nested virt on the hypervisor, reboot the VM |
| Features enabled, WSL still dead | Reboot (exit 3010), re-run |
| `wsl --install` unknown | Update to Windows 10 2004+ / Windows 11 |
| Distro already there | Default is keep + bootstrap. Destroy only with `-ForceRecreate` |
| `hypervisorlaunchtype Off` | Elevated: `bcdedit /set hypervisorlaunchtype Auto` then reboot |
