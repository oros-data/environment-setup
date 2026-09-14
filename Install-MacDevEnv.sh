#!/usr/bin/env bash
# Instalador guiado (pt-BR) do DX enxuto no macOS, inspirado no Omarchy.
# Idempotente. Rode no macOS (Darwin), nunca no Windows, WSL ou Linux.
#
# Compatível com o bash 3.2 do sistema (/bin/bash no macOS) — o ovo/galinha
# do Homebrew: este script precisa rodar antes de existir o bash 5 do brew.
#
# Node: fnm + Node LTS (não brew node, não nvm).
# Docker: Colima + CLI docker (caminho principal). Docker Desktop é alternativo.
# Herdr: instalador oficial; NÃO inicia/para/reinicia o Herdr.
set -euo pipefail

umask 022

BEGIN_ZPROFILE="# --- mac-dev-env begin:zprofile ---"
END_ZPROFILE="# --- mac-dev-env end:zprofile ---"
BEGIN_ZSHRC_PATH="# --- mac-dev-env begin:zshrc-path ---"
END_ZSHRC_PATH="# --- mac-dev-env end:zshrc-path ---"
BEGIN_ZSHRC="# --- mac-dev-env begin:zshrc ---"
END_ZSHRC="# --- mac-dev-env end:zshrc ---"
BEGIN_BASH_PROFILE="# --- mac-dev-env begin:bash-profile ---"
END_BASH_PROFILE="# --- mac-dev-env end:bash-profile ---"
BEGIN_BASHRC_PATH="# --- mac-dev-env begin:bashrc-path ---"
END_BASHRC_PATH="# --- mac-dev-env end:bashrc-path ---"
BEGIN_BASHRC="# --- mac-dev-env begin:bashrc ---"
END_BASHRC="# --- mac-dev-env end:bashrc ---"
BEGIN_HERDR_KEYS="# --- mac-dev-env begin:herdr-keys ---"
END_HERDR_KEYS="# --- mac-dev-env end:herdr-keys ---"
BEGIN_HERDR_THEME="# --- mac-dev-env begin:herdr-theme ---"
END_HERDR_THEME="# --- mac-dev-env end:herdr-theme ---"

INSTALL_BASE_DX=1
INSTALL_DOCKER=0
INSTALL_GH=0
INSTALL_HERDR=0
SETUP_GITHUB_SSH=0
NONINTERACTIVE=0
AGENTS=""
HERDR_KEYS=""
KNOWN_AGENTS="claude codex opencode pi grok kimi cursor"

usage() {
  cat <<'EOF'
Uso: Install-MacDevEnv.sh [flags]

  Instalador de DX no macOS (Darwin). Não rode no Windows, WSL ou Linux.
  No Windows/WSL use: Install-WslDevEnv.ps1 no PowerShell 64-bit elevado.

  --non-interactive      Nunca pergunta; recursos só pelos flags
  --skip-base-dx         Não instala o DX base (git/jq/python/fnm/rust/starship/zoxide/fzf)
  --docker               Colima + CLI docker (caminho principal; não é Docker Desktop)
  --gh                   GitHub CLI (fórmula brew oficial)
  --herdr                Herdr (instalador oficial) + atalhos Omarchy
  --agents LISTA         CLIs separados por vírgula: claude,codex,opencode,pi,grok,kimi,cursor
  --setup-github-ssh     Guia SSH ed25519 (e instala gh se faltar)
  --herdr-keys PATH      TOML com o bloco [keys] Omarchy
  -h, --help             Esta ajuda

Padrão interativo: DX base ligado; o resto desligado até você marcar.
Não cria usuários. Não liga sudo sem senha. Não instala firstmate.
Não inicia, não para e não recarrega o Herdr.

Homebrew:
  Apple Silicon  PATH = /opt/homebrew
  Intel          PATH = /usr/local
EOF
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }
log() { printf '==> %s\n' "$*"; }
ok()  { printf '    %s\n' "$*"; }
warn() { printf '    AVISO: %s\n' "$*" >&2; }
fail() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

script_dir() {
  local src="${BASH_SOURCE[0]:-$0}"
  (cd "$(dirname "$src")" && pwd -P)
}

path_prepend_now() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}"; export PATH ;;
  esac
}

is_wsl() {
  if [[ -n "${WSL_DISTRO_NAME:-}" || -n "${WSL_INTEROP:-}" ]]; then
    return 0
  fi
  if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    return 0
  fi
  return 1
}

os_family() {
  local u
  u="$(uname -s 2>/dev/null || true)"
  case "$u" in
    Darwin) printf 'macos' ;;
    Linux)
      if is_wsl; then
        printf 'wsl'
      else
        printf 'linux'
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'other' ;;
  esac
}

refuse_if_not_macos() {
  local family
  family="$(os_family)"
  case "$family" in
    macos) return 0 ;;
    wsl)
      printf '%s\n' \
        'ERRO: Isto parece o WSL/Linux. Este instalador é só para macOS (Darwin).' \
        'No Windows, rode Install-WslDevEnv.ps1 no PowerShell 64-bit elevado:' \
        '  powershell -ExecutionPolicy Bypass -File .\Install-WslDevEnv.ps1' >&2
      exit 1
      ;;
    linux)
      printf '%s\n' \
        'ERRO: Isto é Linux, não macOS. Este instalador é só para macOS (Darwin).' \
        'No Windows/WSL, rode Install-WslDevEnv.ps1 no PowerShell 64-bit elevado.' >&2
      exit 1
      ;;
    windows)
      printf '%s\n' \
        'ERRO: Isto parece Windows (Git Bash/MSYS/Cygwin). Este instalador é só para macOS.' \
        'Rode Install-WslDevEnv.ps1 no PowerShell 64-bit elevado, não este .sh.' >&2
      exit 1
      ;;
    *)
      printf '%s\n' \
        "ERRO: SO não suportado ($(uname -s 2>/dev/null || echo '?')). Este instalador é só para macOS (Darwin)." \
        'No Windows/WSL use Install-WslDevEnv.ps1.' >&2
      exit 1
      ;;
  esac
}

# Reexecuções substituem o bloco marcado (não empilham duplicatas).
strip_block() {
  local file="$1" begin="$2" end="$3"
  [[ -f "$file" ]] || { : > "$file"; return; }
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mac-dev-env.XXXXXX")"
  awk -v b="$begin" -v e="$end" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    skip != 1 { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

append_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || : > "$file"
  strip_block "$file" "$begin" "$end"
  if [[ -s "$file" ]] && [[ "$(tail -c 1 "$file" | wc -l)" -eq 0 ]]; then
    printf '\n' >> "$file"
  fi
  {
    printf '%s\n' "$begin"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
  } >> "$file"
}

prepend_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || : > "$file"
  strip_block "$file" "$begin" "$end"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mac-dev-env.XXXXXX")"
  {
    printf '%s\n' "$begin"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
    cat "$file"
  } > "$tmp"
  mv "$tmp" "$file"
}

has_word() {
  case " $1 " in
    *" $2 "*) return 0 ;;
    *) return 1 ;;
  esac
}

remove_word() {
  local hay="$1" needle="$2" out="" w
  for w in $hay; do
    if [[ "$w" != "$needle" ]]; then
      if [[ -n "$out" ]]; then
        out="$out $w"
      else
        out="$w"
      fi
    fi
  done
  printf '%s' "$out"
}

add_word() {
  local hay="$1" needle="$2"
  if has_word "$hay" "$needle"; then
    printf '%s' "$hay"
    return
  fi
  if [[ -n "$hay" ]]; then
    printf '%s %s' "$hay" "$needle"
  else
    printf '%s' "$needle"
  fi
}

toggle_word() {
  local hay="$1" needle="$2"
  if has_word "$hay" "$needle"; then
    remove_word "$hay" "$needle"
  else
    add_word "$hay" "$needle"
  fi
}

comma_to_space() {
  printf '%s' "$1" | tr ',;' ' '
}

space_to_comma() {
  local s="$1"
  printf '%s' "$s" | tr -s ' ' ',' | sed 's/^,//;s/,$//'
}

normalize_agents() {
  local raw item out="" known=0
  raw="$(comma_to_space "$AGENTS")"
  for item in $raw; do
    item="$(to_lower "$(trim "$item")")"
    [[ -n "$item" ]] || continue
    known=0
    if has_word "$KNOWN_AGENTS" "$item"; then
      known=1
    fi
    if [[ "$item" == "cursor-agent" ]]; then
      item="cursor"
      known=1
    fi
    if [[ "$known" -eq 1 ]]; then
      out="$(add_word "$out" "$item")"
      continue
    fi
    if [[ "$item" == "firstmate" ]]; then
      warn "firstmate não é instalado por este instalador (não foi oferecido como extra aqui)"
      continue
    fi
    warn "agente desconhecido ignorado: $item (use: $(echo "$KNOWN_AGENTS" | tr ' ' ','))"
  done
  AGENTS="$(space_to_comma "$out")"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --non-interactive|--noninteractive|--NonInteractive)
        NONINTERACTIVE=1
        shift
        ;;
      --skip-base-dx)
        INSTALL_BASE_DX=0
        shift
        ;;
      --docker)
        INSTALL_DOCKER=1
        shift
        ;;
      --gh)
        INSTALL_GH=1
        shift
        ;;
      --herdr)
        INSTALL_HERDR=1
        shift
        ;;
      --setup-github-ssh)
        SETUP_GITHUB_SSH=1
        INSTALL_GH=1
        shift
        ;;
      --agents)
        AGENTS="${2-}"
        if [[ $# -lt 2 ]]; then
          echo "erro: --agents exige uma lista" >&2
          exit 2
        fi
        shift 2
        ;;
      --agents=*)
        AGENTS="${1#--agents=}"
        shift
        ;;
      --herdr-keys)
        HERDR_KEYS="${2-}"
        if [[ -z "$HERDR_KEYS" ]]; then
          echo "erro: --herdr-keys exige um caminho" >&2
          exit 2
        fi
        shift 2
        ;;
      --herdr-keys=*)
        HERDR_KEYS="${1#--herdr-keys=}"
        shift
        ;;
      *)
        echo "erro: argumento desconhecido: $1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
  normalize_agents
  if [[ "$SETUP_GITHUB_SSH" -eq 1 ]]; then
    INSTALL_GH=1
  fi
}

read_yes_no() {
  local prompt="$1" default="${2:-0}" hint ans
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    [[ "$default" -eq 1 ]]
    return
  fi
  if [[ "$default" -eq 1 ]]; then
    hint='S/n'
  else
    hint='s/N'
  fi
  printf '%s [%s] ' "$prompt" "$hint" >&2
  IFS= read -r ans || ans=""
  if [[ -z "$ans" ]]; then
    [[ "$default" -eq 1 ]]
    return
  fi
  case "$(to_lower "$ans")" in
    s|sim|y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

mark() {
  if [[ "$1" -eq 1 ]]; then
    printf '[X]'
  else
    printf '[ ]'
  fi
}

show_plan() {
  local agent_text="nenhum"
  if [[ -n "$AGENTS" ]]; then
    agent_text="$AGENTS"
  fi
  printf '\n'
  printf 'Plano de instalação:\n'
  printf '  %s DX base (git / jq / python3 / node via fnm / rust / starship / zoxide / fzf)\n' "$(mark "$INSTALL_BASE_DX")"
  printf '  %s Docker (Colima + CLI docker)\n' "$(mark "$INSTALL_DOCKER")"
  printf '  %s GitHub CLI (gh)\n' "$(mark "$INSTALL_GH")"
  printf '  %s Herdr + atalhos Omarchy (prefixo ctrl+espaço)\n' "$(mark "$INSTALL_HERDR")"
  printf '  %s CLIs de agentes: %s\n' "$(mark "$([[ -n "$AGENTS" ]] && echo 1 || echo 0)")" "$agent_text"
  printf '  %s Guia GitHub + chave SSH\n' "$(mark "$SETUP_GITHUB_SSH")"
}

agent_label() {
  case "$1" in
    claude) printf 'Claude Code (Anthropic)' ;;
    codex) printf 'Codex CLI (OpenAI)' ;;
    opencode) printf 'OpenCode' ;;
    pi) printf 'Pi coding agent (pi.dev)' ;;
    grok) printf 'Grok CLI (xAI)' ;;
    kimi) printf 'Kimi Code CLI (Moonshot)' ;;
    cursor) printf 'Cursor Agent' ;;
    *) printf '%s' "$1" ;;
  esac
}

read_agent_menu() {
  local selected="" id i n choice piece box
  selected="$(comma_to_space "$AGENTS")"
  printf '\n' >&2
  printf 'Quais CLIs de agentes instalar? (só os escolhidos; firstmate não entra aqui)\n' >&2
  printf 'Digite o número para ligar/desligar, A para todos, N para nenhum, Enter para seguir.\n' >&2
  while true; do
    printf '\n' >&2
    i=1
    for id in $KNOWN_AGENTS; do
      if has_word "$selected" "$id"; then
        box='[X]'
      else
        box='[ ]'
      fi
      printf '  %s %s. %-9s — %s\n' "$box" "$i" "$id" "$(agent_label "$id")" >&2
      i=$((i + 1))
    done
    printf 'Agentes ' >&2
    IFS= read -r choice || choice=""
    choice="$(trim "$choice")"
    if [[ -z "$choice" ]]; then
      break
    fi
    case "$(to_lower "$choice")" in
      a)
        selected="$KNOWN_AGENTS"
        continue
        ;;
      n)
        selected=""
        continue
        ;;
    esac
    oldIFS="$IFS"
    IFS=', '
    set -- $choice
    IFS="$oldIFS"
    for piece in "$@"; do
      case "$piece" in
        ''|*[!0-9]*) ;;
        *)
          n="$piece"
          if [[ "$n" -ge 1 && "$n" -le 7 ]]; then
            i=1
            for id in $KNOWN_AGENTS; do
              if [[ "$i" -eq "$n" ]]; then
                selected="$(toggle_word "$selected" "$id")"
                break
              fi
              i=$((i + 1))
            done
          fi
          ;;
      esac
    done
  done
  AGENTS="$(space_to_comma "$selected")"
}

read_feature_plan() {
  local choice agent_box agent_summary
  printf '\n'
  printf 'Instalação guiada (português do Brasil)\n'
  printf 'Padrão enxuto: DX base ligado; o resto você escolhe.\n'
  printf 'Digite o número para ligar/desligar, Enter para seguir.\n'
  printf 'Conta macOS atual: %s (não criamos usuários novos).\n' "$(id -un)"

  while true; do
    if [[ -n "$AGENTS" ]]; then
      agent_box='[X]'
      agent_summary="$AGENTS"
    else
      agent_box='[ ]'
      agent_summary='nenhum ainda'
    fi
    printf '\n'
    printf '  %s 1. DX base — git, jq, python3, Node (fnm), Rust, starship, zoxide, fzf  (recomendado)\n' "$(mark "$INSTALL_BASE_DX")"
    printf '  %s 2. Docker (Colima + CLI docker; não é Docker Desktop)\n' "$(mark "$INSTALL_DOCKER")"
    printf '  %s 3. GitHub CLI (gh)\n' "$(mark "$INSTALL_GH")"
    printf '  %s 4. Herdr + atalhos estilo Omarchy (prefixo ctrl+espaço)\n' "$(mark "$INSTALL_HERDR")"
    printf '  %s 5. CLIs de agentes (%s)\n' "$agent_box" "$agent_summary"
    printf '  %s 6. Conta GitHub + guia de chave SSH\n' "$(mark "$SETUP_GITHUB_SSH")"
    printf 'Recurso ' >&2
    IFS= read -r choice || choice=""
    choice="$(trim "$choice")"
    if [[ -z "$choice" ]]; then
      break
    fi
    case "$choice" in
      1) INSTALL_BASE_DX=$((1 - INSTALL_BASE_DX)) ;;
      2) INSTALL_DOCKER=$((1 - INSTALL_DOCKER)) ;;
      3) INSTALL_GH=$((1 - INSTALL_GH)) ;;
      4) INSTALL_HERDR=$((1 - INSTALL_HERDR)) ;;
      5) read_agent_menu ;;
      6) SETUP_GITHUB_SSH=$((1 - SETUP_GITHUB_SSH)) ;;
      *) warn 'Escolha 1-6 ou Enter para continuar.' ;;
    esac
  done

  if [[ "$SETUP_GITHUB_SSH" -eq 0 ]]; then
    if read_yes_no 'Você usa GitHub?' 0; then
      SETUP_GITHUB_SSH=1
      ok 'Vamos guiar a chave SSH no final. gh será instalado se ainda não estiver.'
    fi
  fi
  if [[ "$SETUP_GITHUB_SSH" -eq 1 ]]; then
    INSTALL_GH=1
  fi
  if [[ -z "$AGENTS" ]]; then
    if read_yes_no 'Quer escolher CLIs de agentes agora (Claude, Codex, Pi, ...)?' 0; then
      read_agent_menu
    fi
  fi
}

brew_prefix_guess() {
  if [[ -x /opt/homebrew/bin/brew ]]; then
    printf '/opt/homebrew'
    return
  fi
  if [[ -x /usr/local/bin/brew ]]; then
    printf '/usr/local'
    return
  fi
  if need_cmd brew; then
    brew --prefix 2>/dev/null || true
    return
  fi
  local arch
  arch="$(uname -m 2>/dev/null || true)"
  case "$arch" in
    arm64|aarch64) printf '/opt/homebrew' ;;
    *) printf '/usr/local' ;;
  esac
}

load_brew_env() {
  local prefix brew_bin
  prefix="$(brew_prefix_guess)"
  brew_bin="${prefix}/bin/brew"
  if [[ -x "$brew_bin" ]]; then
    eval "$("$brew_bin" shellenv)"
    path_prepend_now "${prefix}/bin"
    return 0
  fi
  if need_cmd brew; then
    eval "$(brew shellenv)"
    return 0
  fi
  return 1
}

ensure_command_line_tools() {
  log "Verificando Command Line Tools (xcode-select)"
  if xcode-select -p >/dev/null 2>&1; then
    ok "Command Line Tools presentes ($(xcode-select -p))"
    return 0
  fi
  cat >&2 <<'EOF'
ERRO: Command Line Tools do Xcode ausentes.

  Rode no Terminal:
    xcode-select --install

  Aceite o diálogo da Apple, espere a instalação e reexecute este script.
  Sem isso o Homebrew e compiladores (python/rust wheels nativos) falham.

  Se o Terminal não enxergar discos/volumes: Ajustes do Sistema → Privacidade e
  Segurança → Acesso Total ao Disco (Full Disk Access) e habilite o Terminal
  (ou iTerm/Warp/Ghostty). Este instalador não liga isso por você.
EOF
  exit 1
}

install_homebrew() {
  local prefix
  if load_brew_env; then
    ok "Homebrew já presente ($(brew --prefix) — $(brew --version | head -n1))"
    return 0
  fi
  log "Instalando Homebrew (script oficial)"
  printf '    Apple Silicon usa /opt/homebrew; Intel usa /usr/local.\n'
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  if ! load_brew_env; then
    fail "Homebrew instalou mas brew não entrou no PATH. Abra um Terminal novo ou: eval \"\$($(brew_prefix_guess)/bin/brew shellenv)\""
  fi
  prefix="$(brew --prefix)"
  ok "Homebrew em ${prefix}"
}

brew_install() {
  local pkg
  if ! need_cmd brew; then
    fail "brew não está no PATH"
  fi
  for pkg in "$@"; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      ok "${pkg} já presente (brew)"
    else
      log "brew install ${pkg}"
      brew install "$pkg"
      ok "${pkg} instalado"
    fi
  done
}

write_env_sh() {
  local home="${1:-$HOME}"
  local env_dir="${home}/.config/mac-dev-env"
  mkdir -p "$env_dir"
  cat > "${env_dir}/env.sh" <<'EOF'
# Gerenciado pelo mac-dev-env. Install-MacDevEnv.sh reescreve este arquivo.
# POSIX: sourced de zsh e bash. Apple Silicon: /opt/homebrew; Intel: /usr/local.

path_prepend() {
  [ -n "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}" ;;
  esac
}

if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

path_prepend "$HOME/.local/bin"
if [ -d "$HOME/.cargo/bin" ]; then
  path_prepend "$HOME/.cargo/bin"
fi
if [ -d "$HOME/.opencode/bin" ]; then
  path_prepend "$HOME/.opencode/bin"
fi
if [ -d "$HOME/.grok/bin" ]; then
  path_prepend "$HOME/.grok/bin"
fi
if [ -d "$HOME/.kimi/bin" ]; then
  path_prepend "$HOME/.kimi/bin"
fi
if [ -d "$HOME/.kimi-code/bin" ]; then
  path_prepend "$HOME/.kimi-code/bin"
fi
if [ -d "$HOME/.cursor/bin" ]; then
  path_prepend "$HOME/.cursor/bin"
fi

if command -v fnm >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then
    eval "$(fnm env --shell zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then
    eval "$(fnm env --shell bash)"
  fi
fi

export PATH
EOF
  ok "escreveu ${env_dir}/env.sh"
}

configure_shell_rc() {
  local home="${1:-$HOME}"
  local zprofile="${home}/.zprofile"
  local zshrc="${home}/.zshrc"
  local bprofile="${home}/.bash_profile"
  local bashrc="${home}/.bashrc"

  write_env_sh "$home"

  append_block "$zprofile" "$BEGIN_ZPROFILE" "$END_ZPROFILE" \
'# mac-dev-env PATH / brew / fnm / cargo (zsh login)
if [ -f "$HOME/.config/mac-dev-env/env.sh" ]; then
  . "$HOME/.config/mac-dev-env/env.sh"
fi'

  prepend_block "$zshrc" "$BEGIN_ZSHRC_PATH" "$END_ZSHRC_PATH" \
'# mac-dev-env PATH mesmo para zsh não-login (VS Code, etc.)
if [ -f "$HOME/.config/mac-dev-env/env.sh" ]; then
  . "$HOME/.config/mac-dev-env/env.sh"
fi'

  append_block "$zshrc" "$BEGIN_ZSHRC" "$END_ZSHRC" \
'# Prompt estilo Omarchy + jumper + completions (só interativo)
if [[ -o interactive ]]; then
  autoload -Uz compinit
  compinit -C
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell zsh --use-on-cd)"
  fi
  if command -v starship >/dev/null 2>&1; then
    eval "$(starship init zsh)"
  fi
  if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
  fi
  _mac_dev_env_brew_prefix=""
  if command -v brew >/dev/null 2>&1; then
    _mac_dev_env_brew_prefix="$(brew --prefix 2>/dev/null || true)"
  elif [ -x /opt/homebrew/bin/brew ]; then
    _mac_dev_env_brew_prefix="/opt/homebrew"
  elif [ -x /usr/local/bin/brew ]; then
    _mac_dev_env_brew_prefix="/usr/local"
  fi
  if [ -n "$_mac_dev_env_brew_prefix" ] && [ -f "$_mac_dev_env_brew_prefix/opt/fzf/shell/key-bindings.zsh" ]; then
    . "$_mac_dev_env_brew_prefix/opt/fzf/shell/key-bindings.zsh"
  fi
  if [ -n "$_mac_dev_env_brew_prefix" ] && [ -f "$_mac_dev_env_brew_prefix/opt/fzf/shell/completion.zsh" ]; then
    . "$_mac_dev_env_brew_prefix/opt/fzf/shell/completion.zsh"
  fi
  unset _mac_dev_env_brew_prefix
  bindkey "\e[A" history-search-backward
  bindkey "\e[B" history-search-forward
  bindkey "\eOA" history-search-backward
  bindkey "\eOB" history-search-forward
fi'

  append_block "$bprofile" "$BEGIN_BASH_PROFILE" "$END_BASH_PROFILE" \
'# mac-dev-env PATH / brew / fnm / cargo (bash login)
if [ -f "$HOME/.config/mac-dev-env/env.sh" ]; then
  . "$HOME/.config/mac-dev-env/env.sh"
fi
if [ -f "$HOME/.bashrc" ]; then
  . "$HOME/.bashrc"
fi'

  prepend_block "$bashrc" "$BEGIN_BASHRC_PATH" "$END_BASHRC_PATH" \
'# mac-dev-env PATH mesmo para bash não interativo
if [ -f "$HOME/.config/mac-dev-env/env.sh" ]; then
  . "$HOME/.config/mac-dev-env/env.sh"
fi'

  append_block "$bashrc" "$BEGIN_BASHRC" "$END_BASHRC" \
'# Prompt estilo Omarchy + jumper (só interativo). bash-completion@2 precisa de bash 4+.
if [[ $- == *i* ]]; then
  if command -v brew >/dev/null 2>&1; then
    _mac_dev_env_bcp="$(brew --prefix 2>/dev/null)/etc/profile.d/bash_completion.sh"
    if [ -f "$_mac_dev_env_bcp" ]; then
      . "$_mac_dev_env_bcp"
    fi
    unset _mac_dev_env_bcp
  fi
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash --use-on-cd)"
  fi
  if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
  fi
  if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init bash)"
  fi
  _mac_dev_env_brew_prefix=""
  if command -v brew >/dev/null 2>&1; then
    _mac_dev_env_brew_prefix="$(brew --prefix 2>/dev/null || true)"
  fi
  if [ -n "$_mac_dev_env_brew_prefix" ] && [ -f "$_mac_dev_env_brew_prefix/opt/fzf/shell/key-bindings.bash" ]; then
    . "$_mac_dev_env_brew_prefix/opt/fzf/shell/key-bindings.bash"
  fi
  if [ -n "$_mac_dev_env_brew_prefix" ] && [ -f "$_mac_dev_env_brew_prefix/opt/fzf/shell/completion.bash" ]; then
    . "$_mac_dev_env_brew_prefix/opt/fzf/shell/completion.bash"
  fi
  unset _mac_dev_env_brew_prefix
  bind '"\e[A": history-search-backward'
  bind '"\e[B": history-search-forward'
fi'

  ok "rc do shell atualizado (zsh + bash; blocos marcados; reexecução segura)"
}

install_rustup() {
  if [[ -x "${HOME}/.cargo/bin/rustc" ]]; then
    ok "rust já presente ($("${HOME}/.cargo/bin/rustc" --version))"
    return
  fi
  if need_cmd rustc; then
    ok "rust já presente ($(rustc --version))"
    return
  fi
  log "Instalando Rust (rustup, stable — não a fórmula brew rust)"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
  path_prepend_now "${HOME}/.cargo/bin"
  ok "rustup instalado"
}

install_fnm_node() {
  if ! need_cmd fnm; then
    log "Instalando fnm (fórmula brew; Node LTS via fnm, não brew node)"
    brew_install fnm
  else
    ok "fnm já presente ($(fnm --version 2>/dev/null || echo ok))"
  fi
  if ! need_cmd fnm; then
    fail "fnm não entrou no PATH depois do brew install"
  fi
  eval "$(fnm env --shell bash)"
  log "Garantindo Node LTS via fnm"
  fnm install --lts
  fnm default lts-latest >/dev/null 2>&1 || fnm default "$(fnm current)"
  eval "$(fnm env --shell bash)"
  ok "node $(node --version 2>/dev/null || echo '?') / npm $(npm --version 2>/dev/null || echo '?')"
}

install_base_dx() {
  log "Instalando DX base (fórmulas brew oficiais + rustup + fnm LTS)"
  brew_install git jq python3 fzf starship zoxide bash-completion@2
  if ! need_cmd curl; then
    fail "curl ausente (vem com o macOS / CLT)"
  else
    ok "curl presente ($(curl --version | head -n1))"
  fi
  install_fnm_node
  install_rustup
  if [[ -f "${HOME}/.cargo/env" ]]; then
    # rustup foi chamado com --no-modify-path; carrega só neste processo.
    # shellcheck disable=SC1091
    . "${HOME}/.cargo/env"
  fi
}

install_docker_colima() {
  log "Instalando Docker via Colima (caminho principal; não é Docker Desktop)"
  brew_install colima docker docker-compose
  ok "CLI docker + Colima presentes"
  if need_cmd colima; then
    if colima status >/dev/null 2>&1; then
      ok "Colima já está em execução"
    else
      if [[ "$NONINTERACTIVE" -eq 1 ]]; then
        log "Iniciando Colima (primeira vez baixa a imagem da VM)"
        if colima start; then
          ok "Colima iniciado"
        else
          warn "colima start falhou. Depois: colima start && docker run --rm hello-world"
        fi
      else
        if read_yes_no 'Iniciar Colima agora (VM; precisa de virtualização)?' 1; then
          log "Iniciando Colima"
          if colima start; then
            ok "Colima iniciado"
          else
            warn "colima start falhou. Depois: colima start"
          fi
        else
          ok "Pulando colima start. Quando quiser: colima start"
        fi
      fi
    fi
  fi
  printf '    Quem preferir Docker Desktop: não use este item; instale o cask à parte\n'
  printf '    (brew install --cask docker) e não rode Colima em paralelo.\n'
}

install_gh_cli() {
  if need_cmd gh; then
    ok "gh já presente ($(gh --version 2>/dev/null | head -n1))"
    return
  fi
  log "Instalando GitHub CLI (fórmula brew oficial)"
  brew_install gh
}

resolve_herdr_keys_src() {
  if [[ -n "$HERDR_KEYS" && -f "$HERDR_KEYS" ]]; then
    printf '%s' "$HERDR_KEYS"
    return
  fi
  local sibling
  sibling="$(script_dir)/guest/herdr-omarchy-keys.toml"
  if [[ -f "$sibling" ]]; then
    printf '%s' "$sibling"
    return
  fi
  printf ''
}

strip_toml_table() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/mac-dev-env.XXXXXX")"
  awk -v name="$name" '
    BEGIN { skip=0 }
    {
      line=$0
      t=line
      sub(/\r$/, "", t)
    }
    t ~ "^\\[" name "\\]" { skip=1; next }
    t ~ "^\\[" name "\\." { skip=1; next }
    skip==1 && t ~ /^\[[A-Za-z0-9_-]+/ {
      skip=0
    }
    skip!=1 { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

merge_herdr_keys() {
  local home="${1:-$HOME}"
  local src
  src="$(resolve_herdr_keys_src)"
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "erro: template de atalhos Herdr não encontrado (passe --herdr-keys ou mantenha guest/herdr-omarchy-keys.toml)" >&2
    exit 1
  fi
  local dest="${home}/.config/herdr/config.toml"
  mkdir -p "$(dirname "$dest")"
  [[ -f "$dest" ]] || : > "$dest"
  tr -d '\r' < "$dest" > "${dest}.nocr"
  mv "${dest}.nocr" "$dest"

  strip_block "$dest" "$BEGIN_HERDR_KEYS" "$END_HERDR_KEYS"
  strip_toml_table "$dest" "keys"

  local body
  body="$(tr -d '\r' < "$src")"
  append_block "$dest" "$BEGIN_HERDR_KEYS" "$END_HERDR_KEYS" "$body"

  if ! grep -qE '^\[theme\]' "$dest"; then
    append_block "$dest" "$BEGIN_HERDR_THEME" "$END_HERDR_THEME" \
'# tokyo-night, como no config Omarchy do captain
[theme]
name = "tokyo-night"
auto_switch = false'
  fi
  ok "atalhos Omarchy gravados em ${dest} (outras seções preservadas)"
}

install_herdr() {
  mkdir -p "${HOME}/.local/bin"
  path_prepend_now "${HOME}/.local/bin"
  if need_cmd herdr; then
    ok "herdr já presente ($(herdr --version 2>/dev/null | head -n1 || echo ok))"
  else
    log "Instalando Herdr (instalador oficial herdr.dev)"
    curl -fsSL https://herdr.dev/install.sh | sh
    path_prepend_now "${HOME}/.local/bin"
    ok "herdr instalado"
  fi
  merge_herdr_keys "$HOME"
  ok "Herdr NÃO foi iniciado/parado/reiniciado por este instalador"
}

ensure_node_for_agents() {
  if need_cmd node && need_cmd npm; then
    return
  fi
  warn "Node/npm ausentes; instalando fnm + Node LTS (dependência do agente)"
  install_fnm_node
}

install_agent_claude() {
  if need_cmd claude; then
    ok "claude já presente ($(claude --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  log "Instalando Claude Code (instalador oficial)"
  curl -fsSL https://claude.ai/install.sh | bash
  ok "claude instalado"
}

install_agent_codex() {
  if need_cmd codex; then
    ok "codex já presente ($(codex --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  log "Instalando Codex CLI (instalador oficial)"
  curl -fsSL https://chatgpt.com/codex/install.sh | sh
  ok "codex instalado"
}

install_agent_opencode() {
  path_prepend_now "${HOME}/.opencode/bin"
  if need_cmd opencode; then
    ok "opencode já presente ($(opencode --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  log "Instalando OpenCode (instalador oficial)"
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
  path_prepend_now "${HOME}/.opencode/bin"
  ok "opencode instalado"
}

install_agent_pi() {
  if need_cmd pi; then
    ok "pi já presente ($(pi --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  ensure_node_for_agents
  log "Instalando Pi coding agent (pacote oficial @earendil-works/pi-coding-agent)"
  mkdir -p "${HOME}/.local"
  npm install -g --prefix "${HOME}/.local" @earendil-works/pi-coding-agent
  path_prepend_now "${HOME}/.local/bin"
  ok "pi instalado"
}

install_agent_grok() {
  path_prepend_now "${HOME}/.grok/bin"
  if need_cmd grok; then
    ok "grok já presente ($(grok --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  log "Instalando Grok CLI (instalador oficial x.ai)"
  curl -fsSL https://x.ai/cli/install.sh | bash
  path_prepend_now "${HOME}/.grok/bin"
  ok "grok instalado"
}

install_agent_kimi() {
  if need_cmd kimi; then
    ok "kimi já presente ($(kimi --version 2>/dev/null | head -n1 || echo ok))"
    return
  fi
  log "Instalando Kimi Code CLI (instalador oficial)"
  curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
  ok "kimi instalado"
}

install_agent_cursor() {
  if need_cmd cursor-agent || need_cmd agent; then
    ok "cursor agent já presente"
    return
  fi
  log "Instalando Cursor Agent (instalador oficial)"
  curl -fsSL https://cursor.com/install | bash
  ok "cursor agent instalado"
}

install_chosen_agents() {
  local raw item
  raw="$(comma_to_space "$AGENTS")"
  if [[ -z "$raw" ]]; then
    return
  fi
  log "Instalando CLIs de agentes selecionados"
  for item in $raw; do
    item="$(to_lower "$item")"
    case "$item" in
      claude) install_agent_claude ;;
      codex) install_agent_codex ;;
      opencode) install_agent_opencode ;;
      pi) install_agent_pi ;;
      grok) install_agent_grok ;;
      kimi) install_agent_kimi ;;
      cursor) install_agent_cursor ;;
      '') ;;
      *) warn "agente desconhecido ignorado: $item" ;;
    esac
  done
}

github_ssh_guide() {
  log "Guia GitHub + chave SSH (ed25519)"
  printf '    Nunca compartilhe nem envie a chave PRIVADA. Só a .pub.\n'
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
  if [[ -f "${HOME}/.ssh/id_ed25519" ]]; then
    ok "chave ed25519 já existe (não sobrescrevemos)"
  else
    ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519" -C "mac-dev-env" -N ""
    ok "chave nova gerada em ~/.ssh/id_ed25519 (passphrase vazia; troque com ssh-keygen -p se quiser)"
  fi
  chmod 600 "${HOME}/.ssh/id_ed25519"
  chmod 644 "${HOME}/.ssh/id_ed25519.pub"
  printf '\n'
  printf 'Chave pública (cole no GitHub):\n'
  cat "${HOME}/.ssh/id_ed25519.pub"
  printf '\n'
  printf 'No GitHub: Settings -> SSH and GPG keys -> New SSH key\n'
  printf '  https://github.com/settings/keys\n'
  printf 'Ou: gh auth login   (GitHub.com, HTTPS ou SSH, login pelo navegador)\n'
  if [[ "$NONINTERACTIVE" -eq 1 ]]; then
    ok "NonInteractive: chave pronta, sem abrir o navegador."
  else
    if read_yes_no 'Abrir a página de chaves SSH do GitHub no navegador?' 1; then
      if need_cmd open; then
        open 'https://github.com/settings/keys' || true
      else
        warn "comando open indisponível; abra https://github.com/settings/keys"
      fi
    fi
    printf 'Depois de cadastrar a chave pública, testamos ssh -T git@github.com\n'
    printf 'Enter para testar (ou Ctrl+C para pular) ' >&2
    IFS= read -r _ || true
  fi
  log "Testando ssh -T git@github.com"
  ssh -o StrictHostKeyChecking=accept-new -T git@github.com || true
  ok 'Teste SSH disparado (o GitHub costuma responder "Hi <user>!" com código 1 — isso é sucesso).'
}

print_summary() {
  cat <<EOF

Bootstrap mac-dev-env concluído para $(id -un) em $(uname -s) $(uname -m).

  brew     $(brew --prefix 2>/dev/null || echo 'não no PATH')
  python3  $(python3 --version 2>/dev/null || echo 'não no PATH / não escolhido')
  node     $(node --version 2>/dev/null || echo 'abra um shell novo / não escolhido')
  rustc    $(rustc --version 2>/dev/null || echo 'abra um shell novo / não escolhido')
  starship $(starship --version 2>/dev/null | head -n1 || echo 'abra um shell novo / não escolhido')
  zoxide   $(zoxide --version 2>/dev/null || echo 'abra um shell novo / não escolhido')
  docker   $(docker --version 2>/dev/null || echo 'não escolhido')
  gh       $(gh --version 2>/dev/null | head -n1 || echo 'não escolhido')
  herdr    $(herdr --version 2>/dev/null | head -n1 || echo 'não escolhido')

  Abra um Terminal novo (ou: exec zsh -l)
  PATH do Homebrew: Apple Silicon = /opt/homebrew ; Intel = /usr/local
EOF
  if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
    printf '\n  Docker: Colima. Se o daemon não estiver no ar: colima start\n'
    printf '  Teste: docker run --rm hello-world\n'
    printf '  Não rode Docker Desktop por cima do Colima (conflito).\n'
  fi
  if [[ "$INSTALL_HERDR" -eq 1 ]]; then
    printf '\n  Herdr: este instalador NÃO inicia o Herdr. Anexe você: herdr\n'
    printf '  Atalhos Omarchy: prefixo ctrl+espaço (guest/herdr-omarchy-keys.toml).\n'
  fi
  if [[ "$SETUP_GITHUB_SSH" -eq 1 ]]; then
    printf '\n  GitHub: se o teste SSH falhou, cadastre a .pub em https://github.com/settings/keys\n'
  fi
  printf '\nReexecução (idempotente):\n'
  printf '  ./Install-MacDevEnv.sh\n'
}

run_install() {
  ensure_command_line_tools
  install_homebrew
  if [[ "$INSTALL_BASE_DX" -eq 1 ]]; then
    install_base_dx
  else
    ok "DX base desligado; pulando git/jq/python/fnm/rust/starship/zoxide/fzf"
  fi
  if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
    install_docker_colima
  fi
  if [[ "$INSTALL_GH" -eq 1 ]]; then
    install_gh_cli
  fi
  if [[ "$INSTALL_HERDR" -eq 1 ]]; then
    install_herdr
  fi
  install_chosen_agents
  configure_shell_rc "$HOME"
  if [[ "$SETUP_GITHUB_SSH" -eq 1 ]]; then
    github_ssh_guide
  fi
  print_summary
}

main() {
  parse_args "$@"
  refuse_if_not_macos
  log "Instalador mac-dev-env (somente Darwin)"
  ok "usuário $(id -un) — não criamos contas novas e não ligamos sudo sem senha"
  if [[ "$NONINTERACTIVE" -eq 0 ]]; then
    read_feature_plan
  fi
  show_plan
  run_install
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
