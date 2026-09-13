# Project agent memory

Windows host entrypoint is `Install-WslDevEnv.ps1`. Guest install is `guest/bootstrap.sh`. Operator docs: `README.md`.

- Run the `.ps1` from elevated 64-bit **Windows** PowerShell (`powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1 -Username …`). Never from inside WSL.
- Do not unregister an existing distro unless the user passed `-ForceRecreate`.
- Node is **fnm** + LTS (not nvm / NodeSource). Keep PATH in `~/.config/wsl-dev-env/env.sh` via marked rc blocks so re-runs do not stack duplicates.
- Linux scripts are LF; PowerShell is CRLF (see `.gitattributes`).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
