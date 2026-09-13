#!/usr/bin/env bash
# Lean Omarchy-inspired WSL Ubuntu bootstrap.
# Idempotent: safe to re-run. No GUI stack, no kitchen-sink CLIs.
#
# Node: fnm (Fast Node Manager) + Node LTS.
#   Why fnm, not nvm or NodeSource: one small Rust binary, no extra apt repo,
#   no multi-hundred-line bashrc hook. PATH is owned by
#   ~/.config/wsl-dev-env/env.sh so re-runs do not stack duplicate entries.
#
# Usage:
#   bootstrap.sh --user NAME            # as root (Windows entrypoint)
#   bootstrap.sh                        # as the linux user (re-run inside WSL)
#   bootstrap.sh --user NAME --system-only
#   bootstrap.sh --user NAME --user-only
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

USER_NAME=""
SYSTEM_ONLY=0
USER_ONLY=0

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--user NAME] [--system-only|--user-only]

  --user NAME     Linux account to configure (required when running as root)
  --system-only   apt, locale, user, /etc/wsl.conf (must be root)
  --user-only     rustup, fnm/Node LTS, starship, zoxide, shell rc
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      USER_NAME="${2:-}"
      if [[ -z "$USER_NAME" ]]; then
        echo "error: --user requires a username" >&2
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SYSTEM_ONLY" -eq 1 && "$USER_ONLY" -eq 1 ]]; then
  echo "error: --system-only and --user-only are mutually exclusive" >&2
  exit 2
fi

if [[ -z "$USER_NAME" ]]; then
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "error: as root, pass --user <linux-username>" >&2
    exit 2
  fi
  USER_NAME="$(id -un)"
fi

if [[ ! "$USER_NAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "error: invalid Linux username: $USER_NAME" >&2
  echo "       lowercase letters, digits, underscore, hyphen; start with a letter or _" >&2
  exit 2
fi

need_cmd() { command -v "$1" >/dev/null 2>&1; }
log() { printf '==> %s\n' "$*"; }
ok()  { printf '    %s\n' "$*"; }

script_self() {
  if need_cmd readlink; then
    readlink -f "$0" 2>/dev/null && return
  fi
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$0"
}

path_prepend_now() {
  case ":$PATH:" in
    *":$1:"*) ;;
    *) PATH="$1${PATH:+:$PATH}"; export PATH ;;
  esac
}

# Re-runs replace the marked block in place (no duplicate stacking).
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
  log "Installing base apt packages (idempotent, no recommends)"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    adduser \
    bash-completion \
    build-essential \
    ca-certificates \
    curl \
    fzf \
    git \
    jq \
    locales \
    python-is-python3 \
    python3 \
    python3-dev \
    python3-pip \
    python3-venv \
    sudo \
    unzip \
    xz-utils
  ok "apt packages present"
}

ensure_locale() {
  log "Ensuring en_US.UTF-8 locale"
  if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
    ok "locale already available"
    return
  fi
  if [[ -f /etc/locale.gen ]]; then
    sed -i 's/^#[[:space:]]*en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    if ! grep -qE '^en_US\.UTF-8 UTF-8' /etc/locale.gen; then
      printf '%s\n' 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    fi
  fi
  locale-gen en_US.UTF-8 >/dev/null
  update-locale LANG=en_US.UTF-8
  ok "locale generated"
}

# Preserve unknown wsl.conf keys; only pin [user] default and [boot] systemd.
ensure_wsl_conf() {
  local conf=/etc/wsl.conf
  local tmp
  tmp="$(mktemp)"
  log "Configuring /etc/wsl.conf (default user=${USER_NAME}, systemd=true)"
  if [[ ! -f "$conf" ]]; then
    cat > "$conf" <<EOF
[user]
default=${USER_NAME}

[boot]
systemd=true
EOF
    ok "wrote new /etc/wsl.conf"
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
  ok "updated /etc/wsl.conf"
}

ensure_linux_user() {
  local created=0
  if getent passwd "$USER_NAME" >/dev/null; then
    ok "user ${USER_NAME} already exists"
  else
    log "Creating user ${USER_NAME}"
    # Personal dev box: empty password + NOPASSWD sudo so bootstrap is
    # non-interactive. Set a password later with `passwd` if you want.
    adduser --disabled-password --gecos "" "$USER_NAME"
    created=1
    ok "created ${USER_NAME} (no password; run passwd inside WSL)"
  fi

  if getent group sudo >/dev/null; then
    if id -nG "$USER_NAME" | tr ' ' '\n' | grep -qx sudo; then
      ok "${USER_NAME} already in sudo"
    else
      usermod -aG sudo "$USER_NAME"
      ok "added ${USER_NAME} to sudo"
    fi
  fi

  local dropin="/etc/sudoers.d/90-wsl-dev-env-${USER_NAME}"
  if [[ "$created" -eq 1 && ! -f "$dropin" ]]; then
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "$dropin"
    chmod 440 "$dropin"
    visudo -cf "$dropin" >/dev/null
    ok "passwordless sudo for ${USER_NAME} (dev-box convenience)"
  elif [[ -f "$dropin" ]]; then
    ok "sudoers drop-in already present"
  else
    ok "left sudoers unchanged for existing account ${USER_NAME}"
  fi
}

write_env_sh() {
  local home="$1"
  local env_dir="${home}/.config/wsl-dev-env"
  mkdir -p "$env_dir"
  cat > "${env_dir}/env.sh" <<'EOF'
# Managed by wsl-dev-env. guest/bootstrap.sh rewrites this file.
# Sourced from .profile and from the top of .bashrc (before the interactive
# guard) so `wsl node` / `wsl cargo` see user toolchains.

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

# fnm (Fast Node Manager)
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
  ok "wrote ${env_dir}/env.sh"
}

configure_shell_rc() {
  local home="$1"
  local bashrc="${home}/.bashrc"
  local profile="${home}/.profile"

  [[ -f "$profile" ]] || : > "$profile"
  [[ -f "$bashrc" ]] || : > "$bashrc"

  write_env_sh "$home"

  append_block "$profile" "$BEGIN_PROFILE" "$END_PROFILE" \
'# wsl-dev-env PATH / fnm / cargo (login shells)
if [ -f "$HOME/.config/wsl-dev-env/env.sh" ]; then
  . "$HOME/.config/wsl-dev-env/env.sh"
fi'

  # Sit above Ubuntu's "return if not interactive" guard.
  prepend_block "$bashrc" "$BEGIN_BASHRC_PATH" "$END_BASHRC_PATH" \
'# wsl-dev-env PATH even for non-interactive bash
if [ -f "$HOME/.config/wsl-dev-env/env.sh" ]; then
  . "$HOME/.config/wsl-dev-env/env.sh"
fi'

  append_block "$bashrc" "$BEGIN_BASHRC" "$END_BASHRC" \
'# Omarchy-style prompt + directory jumper (interactive only)
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
  ok "shell rc updated (marked blocks; re-run safe)"
}

install_rustup() {
  if [[ -x "${HOME}/.cargo/bin/rustc" ]]; then
    ok "rust already present ($("${HOME}/.cargo/bin/rustc" --version))"
    return
  fi
  if need_cmd rustc; then
    ok "rust already present ($(rustc --version))"
    return
  fi
  log "Installing Rust (rustup, stable)"
  curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path
  ok "rustup installed"
}

install_fnm_node() {
  local fnm_dir="${HOME}/.local/share/fnm"
  mkdir -p "${HOME}/.local/bin" "$fnm_dir"
  if [[ ! -x "${fnm_dir}/fnm" ]] && ! need_cmd fnm; then
    log "Installing fnm (Fast Node Manager)"
    curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir "$fnm_dir" --skip-shell
    ok "fnm installed"
  else
    ok "fnm already present"
  fi
  path_prepend_now "$fnm_dir"
  eval "$(fnm env --shell bash)"
  log "Ensuring Node LTS via fnm"
  fnm install --lts
  fnm default lts-latest >/dev/null 2>&1 || fnm default "$(fnm current)"
  eval "$(fnm env --shell bash)"
  ok "node $(node --version 2>/dev/null || echo '?') / npm $(npm --version 2>/dev/null || echo '?')"
}

install_starship() {
  mkdir -p "${HOME}/.local/bin"
  path_prepend_now "${HOME}/.local/bin"
  if need_cmd starship; then
    ok "starship already present ($(starship --version | head -n1))"
    return
  fi
  log "Installing starship"
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "${HOME}/.local/bin"
  ok "starship installed"
}

install_zoxide() {
  mkdir -p "${HOME}/.local/bin"
  path_prepend_now "${HOME}/.local/bin"
  if need_cmd zoxide; then
    ok "zoxide already present ($(zoxide --version))"
    return
  fi
  log "Installing zoxide"
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
  ok "zoxide installed"
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
  ok "user completions in ${dest}"
}

run_system_stage() {
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: system stage must run as root" >&2
    exit 1
  fi
  apt_packages
  ensure_locale
  ensure_linux_user
  ensure_wsl_conf
}

run_user_stage() {
  local home
  home="$(user_home)"
  if [[ -z "$home" || ! -d "$home" ]]; then
    echo "error: home directory for ${USER_NAME} not found" >&2
    exit 1
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    echo "error: user stage must not run as root" >&2
    exit 1
  fi
  if [[ "$(id -un)" != "$USER_NAME" ]]; then
    echo "error: user stage expected to run as ${USER_NAME}, not $(id -un)" >&2
    exit 1
  fi

  export HOME="$home"
  cd "$home"
  mkdir -p "${HOME}/.local/bin" "${HOME}/.local/share"
  path_prepend_now "${HOME}/.local/bin"
  if [[ -d "${HOME}/.cargo/bin" ]]; then
    path_prepend_now "${HOME}/.cargo/bin"
  fi

  install_rustup
  if [[ -f "${HOME}/.cargo/env" ]]; then
    # rustup was invoked with --no-modify-path; load for this process only.
    # shellcheck disable=SC1091
    . "${HOME}/.cargo/env"
  fi
  install_fnm_node
  install_starship
  install_zoxide
  write_completions
  configure_shell_rc "$home"
}

print_summary() {
  cat <<EOF

wsl-dev-env guest bootstrap complete.

  python3  $(python3 --version 2>/dev/null || echo 'not on PATH yet')
  node     $(node --version 2>/dev/null || echo 'open a new shell')
  rustc    $(rustc --version 2>/dev/null || echo 'open a new shell')
  starship $(starship --version 2>/dev/null | head -n1 || echo 'open a new shell')
  zoxide   $(zoxide --version 2>/dev/null || echo 'open a new shell')

  Open a new WSL shell (or: exec bash -l)
  Optional: passwd          # set a password for ${USER_NAME}
EOF
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

# Full run: system as root, user toolchains as TARGET_USER.
if [[ "$(id -u)" -eq 0 ]]; then
  run_system_stage
  log "Dropping privileges to ${USER_NAME} for toolchains"
  exec runuser -u "$USER_NAME" -- bash "$(script_self)" --user "$USER_NAME" --user-only
fi

if need_cmd sudo && sudo -n true 2>/dev/null; then
  log "Running system stage via sudo"
  sudo -E bash "$(script_self)" --user "$USER_NAME" --system-only
else
  echo "warning: not root and passwordless sudo is unavailable; skipping apt/user/wsl.conf" >&2
  echo "         re-run as root (or: sudo $0 --user ${USER_NAME} --system-only)" >&2
fi

run_user_stage
print_summary
