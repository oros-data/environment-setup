# Project agent memory

Two entrypoints, one repo: Windows WSL and macOS Homebrew. Operator docs: `README.md`. Herdr `[keys]` template (both): `guest/herdr-omarchy-keys.toml`. Do not start/stop/restart Herdr from either installer.

- **Windows:** `Install-WslDevEnv.ps1` (guided **pt-BR** menus + `-NonInteractive` flags) from elevated 64-bit Windows PowerShell. Guest: `guest/bootstrap.sh`. Never run the `.ps1` from inside WSL or from macOS.
- **macOS:** `Install-MacDevEnv.sh` on Darwin only. Detects macOS and **refuses** Linux, WSL, and Windows (Git Bash/MSYS) with a pt-BR error pointing at the `.ps1`. Never run the Mac installer on Windows or WSL as if it were Mac. Flags: `--non-interactive --skip-base-dx --docker --gh --herdr --agents LIST --setup-github-ssh`.
- Do not unregister an existing WSL distro unless the user passed `-ForceRecreate`.
- New **Linux** users require a password collected at install time. Do not default new accounts to empty password + NOPASSWD; `-PasswordlessSudo` is explicit opt-in only. The Mac path uses the existing macOS account — do not create users or enable passwordless sudo there.
- Feature flags from Windows host to guest: `--skip-base-dx --docker --gh --herdr --agents LIST --password-file --passwordless-sudo`.
- Node is **fnm** + LTS (not nvm / NodeSource / brew node). Windows/guest PATH: `~/.config/wsl-dev-env/env.sh`. Mac PATH: `~/.config/mac-dev-env/env.sh` (Homebrew `/opt/homebrew` Apple Silicon, `/usr/local` Intel). Marked rc blocks so re-runs do not stack duplicates.
- Mac Docker primary is **Colima** + CLI `docker` (not Desktop). Windows Docker primary is Engine inside Ubuntu.
- Linux scripts are LF; PowerShell is CRLF (see `.gitattributes`). User-facing strings are pt-BR; identifiers stay English.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
