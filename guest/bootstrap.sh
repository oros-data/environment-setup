#!/usr/bin/env bash
# Bootstrap Omarchy-inspired do Ubuntu no WSL.
# Idempotente: seguro reexecutar. Recursos opcionais via flags.
#
# Node: fnm (Fast Node Manager) + Node LTS.
#   Por que fnm, e não nvm ou NodeSource: um binário Rust pequeno, sem repo
#   extra no apt, sem hook enorme no bashrc. PATH fica em
#   ~/.config/wsl-dev-env/env.sh para reexecuções não empilharem entradas.
#
# Uso:
#   bootstrap.sh --user NOME [flags]          # como root (entrada Windows)
#   bootstrap.sh                              # como o usuário linux (reexecução)
#   bootstrap.sh --user NOME --system-only
#   bootstrap.sh --user NOME --user-only
set -euo pipefail

umask 022
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE="${NEEDRESTART_MODE:-l}"

BEGIN_PROFILE="# --- wsl-dev-env begin:profile ---"
END_PROFILE="# --- wsl-dev-env end:profile ---"
BEGIN_BASHRC_PATH="# --- wsl-dev-env begin:bashrc-path ---"
END_BASHRC_PATH="# --- wsl-dev-env end:bashrc-path ---"
BEGIN_BASHRC="# --- wsl-dev-env begin:bashrc ---"
END_BASHRC="# --- wsl-dev-env end:bashrc ---"
BEGIN_HERDR_KEYS="# --- wsl-dev-env begin:herdr-keys ---"
END_HERDR_KEYS="# --- wsl-dev-env end:herdr-keys ---"
BEGIN_HERDR_THEME="# --- wsl-dev-env begin:herdr-theme ---"
END_HERDR_THEME="# --- wsl-dev-env end:herdr-theme ---"
BEGIN_STARSHIP="# --- wsl-dev-env begin:starship ---"
END_STARSHIP="# --- wsl-dev-env end:starship ---"

USER_NAME=""
SYSTEM_ONLY=0
USER_ONLY=0
INSTALL_BASE_DX=1
INSTALL_DOCKER=0
INSTALL_GH=0
INSTALL_HERDR=0
PASSWORDLESS_SUDO=0
AGENTS=""
PASSWORD_FILE=""
HERDR_KEYS=""

usage() {
  cat <<'EOF'
Uso: bootstrap.sh [--user NOME] [--system-only|--user-only] [recursos]

  --user NOME            Conta Linux a configurar (obrigatório como root)
  --system-only          apt, locale, usuário, /etc/wsl.conf, docker/gh (root)
  --user-only            rustup, fnm/Node LTS, starship, zoxide, herdr, agentes, rc
  --skip-base-dx         Não instala python/node/rust/starship/zoxide/fzf
  --docker               Engine Docker no Ubuntu (get.docker.com)
  --gh                   GitHub CLI (repositório apt oficial)
  --herdr                Herdr (instalador oficial) + atalhos Omarchy
  --herdr-keys PATH      TOML com o bloco [keys] Omarchy
  --agents LISTA         CLIs separados por vírgula: claude,codex,opencode,pi,grok,kimi,cursor
  --passwordless-sudo    sudo sem senha (só se o usuário pediu)
  --password-file PATH   arquivo user:senha para chpasswd (contas novas exigem senha)
EOF
}

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_NAME="${2:-}"
      if [[ -z "$USER_NAME" ]]; then
        echo "erro: --user exige um nome de usuário" >&2
        exit 2
      fi
      shift 2
      ;;
    --user-only)
      USER_ONLY=1
      shift
      ;;
    --system-only)
      SYSTEM_ONLY=1
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
    --herdr-keys)
      HERDR_KEYS="${2:-}"
      if [[ -z "$HERDR_KEYS" ]]; then
        echo "erro: --herdr-keys exige um caminho" >&2
        exit 2
      fi
      shift 2
      ;;
    --agents)
      AGENTS="${2:-}"
      shift 2
      ;;
    --passwordless-sudo)
      PASSWORDLESS_SUDO=1
      shift
      ;;
    --password-file)
      PASSWORD_FILE="${2:-}"
      if [[ -z "$PASSWORD_FILE" ]]; then
        echo "erro: --password-file exige um caminho" >&2
        exit 2
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "erro: argumento desconhecido: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SYSTEM_ONLY" -eq 1 && "$USER_ONLY" -eq 1 ]]; then
  echo "erro: --system-only e --user-only são mutuamente exclusivos" >&2
  exit 2
fi

if [[ -z "$USER_NAME" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "erro: como root, passe --user <usuário-linux>" >&2
    exit 2
  fi
  USER_NAME="$(id -un)"
fi

if [[ ! "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "erro: nome de usuário Linux inválido: $USER_NAME" >&2
  echo "      letras minúsculas, dígitos, _ ou -; comece com letra ou _" >&2
  exit 2
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
log() { printf '==> %s\n' "$*"; }
ok()  { printf '    %s\n' "$*"; }
warn() { printf '    AVISO: %s\n' "$*" >&2; }

script_self() {
  if need_cmd readlink; then
    readlink -f "$0" 2>/dev/null && return
  fi
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0"
}

script_dir() {
  local self
  self="$(script_self)"
  dirname "$self"
}

path_prepend_now() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}"; export PATH ;;
  esac
}

# Reexecuções substituem o bloco marcado (não empilham duplicatas).
strip_block() {
  local file="$1" begin="$2" end="$3"
  [[ -f "$file" ]] || { : > "$file"; return; }
  local tmp
  tmp="$(mktemp)"
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
  tmp="$(mktemp)"
  {
    printf '%s\n' "$begin"
    printf '%s\n' "$content"
    printf '%s\n' "$end"
    cat "$file"
  } > "$tmp"
  mv "$tmp" "$file"
}

user_home() {
  getent passwd "$USER_NAME" | awk -F: '{print $6}'
}

apt_packages() {
  log "Instalando pacotes apt base (idempotente, sem recommends)"
  apt-get update -y
  local pkgs=(
    adduser
    ca-certificates
    curl
    git
    locales
    sudo
    unzip
    xz-utils
    openssh-client
  )
  if [[ "$INSTALL_BASE_DX" -eq 1 ]]; then
    pkgs+=(
      bash-completion
      build-essential
      fzf
      jq
      python-is-python3
      python3
      python3-dev
      python3-pip
      python3-venv
    )
  fi
  apt-get install -y --no-install-recommends "${pkgs[@]}"
  ok "pacotes apt presentes"
}

ensure_locale() {
  log "Garantindo locales en_US.UTF-8 e pt_BR.UTF-8"
  local need_gen=0
  if ! locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    need_gen=1
  fi
  if ! locale -a 2>/dev/null | grep -qiE '^pt_BR\.utf-?8$'; then
    need_gen=1
  fi
  if [[ -f /etc/locale.gen ]]; then
    sed -i 's/^#[[:space:]]*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    sed -i 's/^#[[:space:]]*pt_BR.UTF-8 UTF-8/pt_BR.UTF-8 UTF-8/' /etc/locale.gen
    if ! grep -qE '^en_US\.UTF-8 UTF-8' /etc/locale.gen; then
      printf '%s\n' 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    fi
    if ! grep -qE '^pt_BR\.UTF-8 UTF-8' /etc/locale.gen; then
      printf '%s\n' 'pt_BR.UTF-8 UTF-8' >> /etc/locale.gen
    fi
  fi
  if [[ "$need_gen" -eq 1 ]]; then
    locale-gen en_US.UTF-8 pt_BR.UTF-8 >/dev/null
    update-locale LANG=en_US.UTF-8
    ok "locales gerados"
  else
    ok "locales já disponíveis"
  fi
}

# Preserva chaves desconhecidas do wsl.conf; só fixa [user] default e [boot] systemd.
ensure_wsl_conf() {
  local conf=/etc/wsl.conf
  local tmp
  tmp="$(mktemp)"
  log "Configurando /etc/wsl.conf (usuário padrão=${USER_NAME}, systemd=true)"
  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<EOF
[user]
default=${USER_NAME}

[boot]
systemd=true
EOF
    ok "escreveu /etc/wsl.conf novo"
    return
  fi
  tr -d '\r' < "$conf" | awk -v user="$USER_NAME" '
    BEGIN { in_user=0; in_boot=0; saw_user=0; saw_boot=0; saw_default=0; saw_systemd=0 }
    /^\[user\]/ { in_user=1; in_boot=0; saw_user=1; print; next }
    /^\[boot\]/ { in_boot=1; in_user=0; saw_boot=1; print; next }
    /^\[/ {
      if (in_user && !saw_default) print "default=" user
      if (in_boot && !saw_systemd) print "systemd=true"
      in_user=0; in_boot=0
      print; next
    }
    in_user && $0 ~ /^[[:space:]]*default[[:space:]]*=/ {
      print "default=" user
      saw_default=1
      next
    }
    in_boot && $0 ~ /^[[:space:]]*systemd[[:space:]]*=/ {
      print "systemd=true"
      saw_systemd=1
      next
    }
    { print }
    END {
      if (in_user && !saw_default) print "default=" user
      if (in_boot && !saw_systemd) print "systemd=true"
      if (!saw_user) {
        print ""
        print "[user]"
        print "default=" user
      }
      if (!saw_boot) {
        print ""
        print "[boot]"
        print "systemd=true"
      }
    }
  ' > "$tmp"
  mv "$tmp" "$conf"
  ok "atualizou /etc/wsl.conf"
}

apply_password_file() {
  if [[ -z "$PASSWORD_FILE" ]]; then
    return
  fi
  if [[ ! -f "$PASSWORD_FILE" ]]; then
    echo "erro: arquivo de senha não encontrado: $PASSWORD_FILE" >&2
    exit 1
  fi
  chmod 600 "$PASSWORD_FILE" 2>/dev/null || true
  log "Definindo senha do usuário ${USER_NAME}"
  chpasswd < "$PASSWORD_FILE"
  if need_cmd shred; then
    shred -u "$PASSWORD_FILE" 2>/dev/null || rm -f "$PASSWORD_FILE"
  else
    rm -f "$PASSWORD_FILE"
  fi
  ok "senha aplicada (arquivo temporário removido)"
}

ensure_linux_user() {
  local created=0
  if getent passwd "$USER_NAME" >/dev/null; then
    ok "usuário ${USER_NAME} já existe"
  else
    if [[ -z "$PASSWORD_FILE" || ! -f "$PASSWORD_FILE" ]]; then
      echo "erro: contas novas exigem senha (--password-file). Não criamos senha vazia nem NOPASSWD por padrão." >&2
      exit 1
    fi
    log "Criando usuário ${USER_NAME}"
    adduser --disabled-password --gecos "" "$USER_NAME"
    created=1
    ok "criado ${USER_NAME} (senha será definida em seguida)"
  fi

  apply_password_file

  if getent group sudo >/dev/null; then
    if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx sudo; then
      ok "${USER_NAME} já está no grupo sudo"
    else
      usermod -aG sudo "$USER_NAME"
      ok "adicionou ${USER_NAME} ao grupo sudo"
    fi
  fi

  local dropin="/etc/sudoers.d/90-wsl-dev-env-${USER_NAME}"
  if [[ "$PASSWORDLESS_SUDO" -eq 1 ]]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "$dropin"
    chmod 440 "$dropin"
    visudo -cf "$dropin" >/dev/null
    ok "sudo sem senha para ${USER_NAME} (você pediu explicitamente)"
  else
    if [[ -f "$dropin" ]]; then
      ok "drop-in de sudoers já existe; não removemos na reexecução"
    else
      ok "sudo com senha (padrão). Use --passwordless-sudo só se quiser NOPASSWD."
    fi
  fi

  if [[ "$created" -eq 1 ]]; then
    ok "conta nova com senha configurada pelo instalador"
  fi
}

install_docker_engine() {
  if need_cmd docker && docker --version >/dev/null 2>&1; then
    ok "docker já presente ($(docker --version 2>/dev/null | head -n1))"
  else
    log "Instalando Docker Engine no Ubuntu (get.docker.com)"
    curl -fsSL https://get.docker.com | sh
    ok "Docker Engine instalado"
  fi
  if getent group docker >/dev/null; then
    if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx docker; then
      ok "${USER_NAME} já está no grupo docker"
    else
      usermod -aG docker "$USER_NAME"
      ok "adicionou ${USER_NAME} ao grupo docker"
    fi
  fi
  if [[ -x /usr/sbin/iptables-legacy ]] && need_cmd update-alternatives; then
    update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null 2>&1 || true
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null 2>&1 || true
  fi
  if [[ -d /run/systemd/system ]] && need_cmd systemctl; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    ok "serviço docker habilitado"
  else
    if need_cmd systemctl; then
      systemctl enable docker >/dev/null 2>&1 || true
    fi
    ok "Docker sobe no próximo start do WSL (systemd=true em /etc/wsl.conf)"
  fi
}

install_gh_cli() {
  if need_cmd gh; then
    ok "gh já presente ($(gh --version 2>/dev/null | head -n1))"
    return
  fi
  log "Instalando GitHub CLI (repositório apt oficial)"
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  local arch
  arch="$(dpkg --print-architecture)"
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$arch" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -y
  apt-get install -y --no-install-recommends gh
  ok "gh instalado ($(gh --version 2>/dev/null | head -n1))"
}

write_env_sh() {
  local home="$1"
  local env_dir="${home}/.config/wsl-dev-env"
  mkdir -p "$env_dir"
  cat > "${env_dir}/env.sh" <<'EOF'
# Gerenciado pelo wsl-dev-env. guest/bootstrap.sh reescreve este arquivo.
# Sourced de .profile e do topo de .bashrc (antes do guard interativo)
# para `wsl node` / `wsl cargo` enxergarem as toolchains do usuário.

path_prepend() {
  [ -n "$1" ] || return 0
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}" ;;
  esac
}

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
if [ -d "$HOME/.local/share/fnm" ]; then
  path_prepend "$HOME/.local/share/fnm"
  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
  fi
fi

if [ -z "${LANG:-}" ]; then
  export LANG=en_US.UTF-8
fi

export PATH
EOF
  if [[ "$(id -un)" == "$USER_NAME" ]]; then
    :
  else
    chown -R "${USER_NAME}:${USER_NAME}" "${home}/.config" 2>/dev/null || true
  fi
  ok "escreveu ${env_dir}/env.sh"
}

configure_shell_rc() {
  local home="$1"
  local bashrc="${home}/.bashrc"
  local profile="${home}/.profile"

  [[ -f "$profile" ]] || : > "$profile"
  [[ -f "$bashrc" ]] || : > "$bashrc"

  write_env_sh "$home"

  append_block "$profile" "$BEGIN_PROFILE" "$END_PROFILE" \
'# wsl-dev-env PATH / fnm / cargo (shells de login)
if [ -f "$HOME/.config/wsl-dev-env/env.sh" ]; then
  . "$HOME/.config/wsl-dev-env/env.sh"
fi'

  # Fica acima do guard "return if not interactive" do Ubuntu.
  prepend_block "$bashrc" "$BEGIN_BASHRC_PATH" "$END_BASHRC_PATH" \
'# wsl-dev-env PATH mesmo para bash não interativo
if [ -f "$HOME/.config/wsl-dev-env/env.sh" ]; then
  . "$HOME/.config/wsl-dev-env/env.sh"
fi'

  append_block "$bashrc" "$BEGIN_BASHRC" "$END_BASHRC" \
'# Prompt estilo Omarchy + jumper de diretório (só interativo)
if [[ $- == *i* ]]; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
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
  if [ -f /usr/share/doc/fzf/examples/key-bindings.bash ]; then
    . /usr/share/doc/fzf/examples/key-bindings.bash
  elif [ -f /usr/share/fzf/key-bindings.bash ]; then
    . /usr/share/fzf/key-bindings.bash
  fi
  if [ -f /usr/share/doc/fzf/examples/completion.bash ]; then
    . /usr/share/doc/fzf/examples/completion.bash
  elif [ -f /usr/share/fzf/completion.bash ]; then
    . /usr/share/fzf/completion.bash
  fi
fi'

  if [[ "$(id -un)" != "$USER_NAME" ]]; then
    chown "$USER_NAME:$USER_NAME" "$bashrc" "$profile" 2>/dev/null || true
  fi
  ok "rc do shell atualizado (blocos marcados; reexecução segura)"
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
  log "Instalando Rust (rustup, stable)"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
  ok "rustup instalado"
}

install_fnm_node() {
  local fnm_dir="${HOME}/.local/share/fnm"
  mkdir -p "${HOME}/.local/bin" "$fnm_dir"
  if [[ ! -x "${fnm_dir}/fnm" ]] && ! need_cmd fnm; then
    log "Instalando fnm (Fast Node Manager)"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$fnm_dir" --skip-shell
    ok "fnm instalado"
  else
    ok "fnm já presente"
  fi
  path_prepend_now "$fnm_dir"
  eval "$(fnm env --shell bash)"
  log "Garantindo Node LTS via fnm"
  fnm install --lts
  fnm default lts-latest >/dev/null 2>&1 || fnm default "$(fnm current)"
  eval "$(fnm env --shell bash)"
  ok "node $(node --version 2>/dev/null || echo '?') / npm $(npm --version 2>/dev/null || echo '?')"
}

install_starship() {
  mkdir -p "${HOME}/.local/bin"
  path_prepend_now "${HOME}/.local/bin"
  if need_cmd starship; then
    ok "starship já presente ($(starship --version | head -n1))"
    return
  fi
  log "Instalando starship"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "${HOME}/.local/bin"
  ok "starship instalado"
}

install_zoxide() {
  mkdir -p "${HOME}/.local/bin"
  path_prepend_now "${HOME}/.local/bin"
  if need_cmd zoxide; then
    ok "zoxide já presente ($(zoxide --version))"
    return
  fi
  log "Instalando zoxide"
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
  ok "zoxide instalado"
}

write_completions() {
  local dest="${HOME}/.local/share/bash-completion/completions"
  mkdir -p "$dest"
  if need_cmd rustup; then
    rustup completions bash > "${dest}/rustup"
    rustup completions bash cargo > "${dest}/cargo" 2>/dev/null || true
  fi
  if need_cmd fnm; then
    fnm completions --shell bash > "${dest}/fnm" 2>/dev/null || true
  fi
  if need_cmd gh; then
    gh completion -s bash > "${dest}/gh" 2>/dev/null || true
  fi
  ok "completions do usuário em ${dest}"
}

resolve_herdr_keys_src() {
  if [[ -n "$HERDR_KEYS" && -f "$HERDR_KEYS" ]]; then
    printf '%s' "$HERDR_KEYS"
    return
  fi
  local sibling
  sibling="$(script_dir)/herdr-omarchy-keys.toml"
  if [[ -f "$sibling" ]]; then
    printf '%s' "$sibling"
    return
  fi
  if [[ -f /tmp/wsl-dev-env-herdr-omarchy-keys.toml ]]; then
    printf '%s' /tmp/wsl-dev-env-herdr-omarchy-keys.toml
    return
  fi
  printf ''
}

# Remove uma tabela TOML [name] (e [name.foo]) até a próxima tabela de outro nome.
strip_toml_table() {
  local file="$1" name="$2"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"
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

merge_starship_config() {
  local home="$1"
  local dest="${home}/.config/starship.toml"
  mkdir -p "$(dirname "$dest")"
  [[ -f "$dest" ]] || : > "$dest"
  tr -d '\r' < "$dest" > "${dest}.nocr"
  mv "${dest}.nocr" "$dest"

  strip_block "$dest" "$BEGIN_STARSHIP" "$END_STARSHIP"

  # Embedded starship config
  # Keep in sync with guest/starship-omarchy.toml in the repo
  local body
  body="$(cat <<'STARSHIP_THEME_EOF'
add_newline = true
command_timeout = 200
format = "[$directory$git_branch$git_status]($style)\n$character"

[character]
error_symbol = "[✗](bold cyan)"
success_symbol = "[❯](bold cyan)"

[directory]
truncation_length = 2
truncation_symbol = "…/"
repo_root_style = "bold cyan"
repo_root_format = "[$repo_root]($repo_root_style)[$path]($style)[$read_only]($read_only_style) "

[git_branch]
format = "[$branch]($style) "
style = "italic cyan"

[git_status]
format     = '[$all_status]($style)'
style      = "cyan"
ahead      = "⇡${count} "
diverged   = "⇕⇡${ahead_count}⇣${behind_count} "
behind     = "⇣${count} "
conflicted = " "
up_to_date = " "
untracked  = "? "
modified   = " "
stashed    = ""
staged     = ""
renamed    = ""
deleted    = ""
STARSHIP_THEME_EOF
)"
  append_block "$dest" "$BEGIN_STARSHIP" "$END_STARSHIP" "$body"

  if [[ "$(id -un)" != "$USER_NAME" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${home}/.config" 2>/dev/null || true
  fi
  ok "starship config gravado em ${dest}"
}

merge_herdr_keys() {
  local home="$1"
  local src
  src="$(resolve_herdr_keys_src)"
  if [[ -z "$src" || ! -f "$src" ]]; then
    echo "erro: template de atalhos Herdr não encontrado (passe --herdr-keys)" >&2
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

  if [[ "$(id -un)" != "$USER_NAME" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${home}/.config/herdr" 2>/dev/null || true
  fi
  ok "atalhos Omarchy gravados em ${dest} (outras seções preservadas)"
}

install_herdr_guest() {
  mkdir -p "${HOME}/.local/bin"
  path_prepend_now "${HOME}/.local/bin"
  if need_cmd herdr; then
    ok "herdr já presente ($(herdr --version 2>/dev/null | head -n1 || echo ok))"
  else
    log "Instalando Herdr no Ubuntu (instalador oficial herdr.dev)"
    curl -fsSL https://herdr.dev/install.sh | sh
    path_prepend_now "${HOME}/.local/bin"
    ok "herdr instalado"
  fi
  merge_herdr_keys "$(user_home)"
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
  # O install.sh de pi.dev pede tecla no TTY; o pacote npm é o mesmo
  # (@earendil-works/pi-coding-agent) e roda sem prompt no bootstrap.
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
  local raw="$AGENTS"
  raw="${raw// /}"
  if [[ -z "$raw" ]]; then
    return
  fi
  log "Instalando CLIs de agentes selecionados"
  local IFS=','
  local item
  # shellcheck disable=SC2086
  set -- $raw
  for item in "$@"; do
    item="$(echo "$item" | tr '[:upper:]' '[:lower:]')"
    case "$item" in
      claude) install_agent_claude ;;
      codex) install_agent_codex ;;
      opencode) install_agent_opencode ;;
      pi) install_agent_pi ;;
      grok) install_agent_grok ;;
      kimi) install_agent_kimi ;;
      cursor|cursor-agent) install_agent_cursor ;;
      firstmate)
        warn "firstmate não é instalado por este bootstrap (não foi oferecido como extra aqui)"
        ;;
      '') ;;
      *)
        warn "agente desconhecido ignorado: $item"
        ;;
    esac
  done
}

run_system_stage() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "erro: estágio de sistema precisa ser root" >&2
    exit 1
  fi
  apt_packages
  ensure_locale
  ensure_linux_user
  ensure_wsl_conf
  if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
    install_docker_engine
  fi
  if [[ "$INSTALL_GH" -eq 1 ]]; then
    install_gh_cli
  fi
}

run_user_stage() {
  local home
  home="$(user_home)"
  if [[ -z "$home" || ! -d "$home" ]]; then
    echo "erro: diretório home de ${USER_NAME} não encontrado" >&2
    exit 1
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "erro: estágio de usuário não deve rodar como root" >&2
    exit 1
  fi
  if [[ "$(id -un)" != "$USER_NAME" ]]; then
    echo "erro: estágio de usuário deveria rodar como ${USER_NAME}, não $(id -un)" >&2
    exit 1
  fi

  export HOME="$home"
  cd "$home"
  mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share"
  path_prepend_now "${HOME}/.local/bin"
  if [[ -d "${HOME}/.cargo/bin" ]]; then
    path_prepend_now "${HOME}/.cargo/bin"
  fi

  if [[ "$INSTALL_BASE_DX" -eq 1 ]]; then
    install_rustup
    if [[ -f "${HOME}/.cargo/env" ]]; then
      # rustup foi chamado com --no-modify-path; carrega só neste processo.
      # shellcheck disable=SC1091
      . "${HOME}/.cargo/env"
    fi
    install_fnm_node
    install_starship
    install_zoxide
    write_completions
  else
    ok "DX base desligado; pulando python/node/rust/starship/zoxide/fzf de usuário"
  fi

  if command -v starship >/dev/null 2>&1; then
    merge_starship_config "$home"
  fi

  if [[ "$INSTALL_HERDR" -eq 1 ]]; then
    install_herdr_guest
  fi

  if command -v herdr >/dev/null 2>&1; then
    if [[ "$INSTALL_HERDR" -ne 1 ]]; then
      merge_herdr_keys "$home"
    fi
  fi

  install_chosen_agents
  configure_shell_rc "$home"
}

print_summary() {
  cat <<EOF

Bootstrap wsl-dev-env concluído.

  python3  $(python3 --version 2>/dev/null || echo 'não no PATH / não escolhido')
  node     $(node --version 2>/dev/null || echo 'abra um shell novo / não escolhido')
  rustc    $(rustc --version 2>/dev/null || echo 'abra um shell novo / não escolhido')
  starship $(starship --version 2>/dev/null | head -n1 || echo 'abra um shell novo / não escolhido')
  zoxide   $(zoxide --version 2>/dev/null || echo 'abra um shell novo / não escolhido')
  docker   $(docker --version 2>/dev/null || echo 'não escolhido')
  gh       $(gh --version 2>/dev/null | head -n1 || echo 'não escolhido')
  herdr    $(herdr --version 2>/dev/null | head -n1 || echo 'não escolhido')

  Abra um shell WSL novo (ou: exec bash -l)
EOF
}

user_stage_args() {
  local args=(--user "$USER_NAME" --user-only)
  if [[ "$INSTALL_BASE_DX" -eq 0 ]]; then
    args+=(--skip-base-dx)
  fi
  if [[ "$INSTALL_HERDR" -eq 1 ]]; then
    args+=(--herdr)
  fi
  if [[ -n "$HERDR_KEYS" ]]; then
    args+=(--herdr-keys "$HERDR_KEYS")
  fi
  if [[ -n "$AGENTS" ]]; then
    args+=(--agents "$AGENTS")
  fi
  printf '%s\n' "${args[@]}"
}

if [[ "$SYSTEM_ONLY" -eq 1 ]]; then
  run_system_stage
  exit 0
fi

if [[ "$USER_ONLY" -eq 1 ]]; then
  run_user_stage
  print_summary
  exit 0
fi

# Execução completa: sistema como root, toolchains como TARGET_USER.
if [[ "$(id -u)" -eq 0 ]]; then
  run_system_stage
  log "Baixando privilégios para ${USER_NAME} nas toolchains"
  mapfile -t _user_args < <(user_stage_args)
  exec runuser -u "$USER_NAME" -- bash "$(script_self)" "${_user_args[@]}"
fi

if need_cmd sudo && sudo -n true 2>/dev/null; then
  log "Rodando estágio de sistema via sudo"
  sudo_args=(--user "$USER_NAME" --system-only)
  if [[ "$INSTALL_BASE_DX" -eq 0 ]]; then
    sudo_args+=(--skip-base-dx)
  fi
  if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
    sudo_args+=(--docker)
  fi
  if [[ "$INSTALL_GH" -eq 1 ]]; then
    sudo_args+=(--gh)
  fi
  if [[ "$PASSWORDLESS_SUDO" -eq 1 ]]; then
    sudo_args+=(--passwordless-sudo)
  fi
  if [[ -n "$PASSWORD_FILE" ]]; then
    sudo_args+=(--password-file "$PASSWORD_FILE")
  fi
  sudo -E bash "$(script_self)" "${sudo_args[@]}"
else
  echo "aviso: não é root e sudo sem senha indisponível; pulando apt/usuário/wsl.conf" >&2
  echo "         reexecute como root (ou: sudo $0 --user ${USER_NAME} --system-only)" >&2
fi

run_user_stage
print_summary
