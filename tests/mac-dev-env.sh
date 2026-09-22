#!/usr/bin/env bash
# Testes do instalador macOS que rodam em Linux (recusa de SO, flags, rc).
# Não instalam Homebrew nem baixam pacotes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/Install-MacDevEnv.sh"
FAILS=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILS=$((FAILS + 1))
}

pass() {
  printf 'ok - %s\n' "$*"
}

expect_exit() {
  local want="$1" desc="$2"
  shift 2
  local code=0
  set +e
  "$@" >/dev/null 2>&1
  code=$?
  set -e
  if [[ "$code" -eq "$want" ]]; then
    pass "$desc (exit $want)"
  else
    fail "$desc: esperado exit $want, obteve $code"
  fi
}

expect_stdout() {
  local needle="$1" desc="$2"
  shift 2
  local out
  out="$("$@" 2>&1 || true)"
  if printf '%s' "$out" | grep -Fq -- "$needle"; then
    pass "$desc"
  else
    fail "$desc: não achou '$needle' em: $out"
  fi
}

[[ -f "$SCRIPT" ]] || { echo "script ausente: $SCRIPT" >&2; exit 1; }

bash -n "$SCRIPT"
pass "bash -n Install-MacDevEnv.sh"

expect_exit 0 "help" "$SCRIPT" --help
expect_stdout "Uso:" "help imprime Uso" "$SCRIPT" --help
expect_stdout "--non-interactive" "help lista --non-interactive" "$SCRIPT" --help
expect_stdout "Install-WslDevEnv.ps1" "help aponta o instalador Windows" "$SCRIPT" --help

out="$("$SCRIPT" 2>&1 || true)"
code=0
set +e
"$SCRIPT" >/dev/null 2>&1
code=$?
set -e
if [[ "$code" -eq 1 ]]; then
  pass "recusa Linux/não-Darwin (exit 1)"
else
  fail "recusa Linux: esperado exit 1, obteve $code"
fi
if printf '%s' "$out" | grep -Eq 'macOS|Darwin'; then
  pass "recusa menciona macOS/Darwin"
else
  fail "recusa deveria mencionar macOS/Darwin: $out"
fi
if printf '%s' "$out" | grep -Fq 'Install-WslDevEnv.ps1'; then
  pass "recusa aponta Install-WslDevEnv.ps1"
else
  fail "recusa deveria apontar o .ps1 Windows"
fi

out_wsl="$(WSL_DISTRO_NAME=Ubuntu WSL_INTEROP=/run/WSL/1_interop "$SCRIPT" 2>&1 || true)"
if printf '%s' "$out_wsl" | grep -Fq 'WSL'; then
  pass "recusa WSL cita WSL"
else
  fail "com WSL_DISTRO_NAME deveria citar WSL: $out_wsl"
fi

expect_exit 2 "flag desconhecida" "$SCRIPT" --nao-existe
expect_stdout "desconhecido" "flag desconhecida fala desconhecido" "$SCRIPT" --nao-existe

expect_exit 1 "non-interactive ainda recusa SO" "$SCRIPT" --non-interactive --docker --gh

# Helpers em subshell: o instalador define fail()/exit e não pode clobber este runner.
helper_out="$(ROOT="$ROOT" SCRIPT="$SCRIPT" bash -euo pipefail <<'HELPER'
. "$SCRIPT"
check() { [[ $1 -eq 1 ]] || { echo "FAIL: $2" >&2; exit 1; } }
say() { echo "ok - $*"; }

family="$(os_family)"
case "$family" in
  linux|wsl) say "os_family=$family" ;;
  *) echo "FAIL: os_family inesperado: $family" >&2; exit 1 ;;
esac

parse_args --non-interactive --docker --gh --herdr --agents claude,pi --setup-github-ssh
check "$NONINTERACTIVE" "parse --non-interactive"
check "$INSTALL_DOCKER" "parse --docker"
check "$INSTALL_GH" "parse --gh / ssh liga gh"
check "$INSTALL_HERDR" "parse --herdr"
check "$SETUP_GITHUB_SSH" "parse --setup-github-ssh"
[[ "$AGENTS" == "claude,pi" ]] || { echo "FAIL: parse --agents (obtido '$AGENTS')" >&2; exit 1; }
say "parse_args flags principais"

AGENTS="Claude, CURSOR-AGENT , firstmate, nope"
normalize_agents
[[ "$AGENTS" == "claude,cursor" ]] || { echo "FAIL: normalize_agents: obtido '$AGENTS'" >&2; exit 1; }
say "normalize_agents ignora firstmate/desconhecidos e aceita cursor-agent"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/mac-dev-env-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

f="${tmp}/rc"
printf 'keep-me\n' > "$f"
append_block "$f" "# begin x" "# end x" "hello"
append_block "$f" "# begin x" "# end x" "hello-again"
grep -q 'keep-me' "$f" || { echo "FAIL: append perdeu keep-me" >&2; exit 1; }
grep -q 'hello-again' "$f" || { echo "FAIL: append não escreveu hello-again" >&2; exit 1; }
grep -q '^hello$' "$f" && { echo "FAIL: append não substituiu o bloco" >&2; exit 1; }
say "append_block substitui o bloco marcado"

printf 'body\n' > "$f"
prepend_block "$f" "# begin p" "# end p" "top"
awk 'NR==1{exit !($0=="# begin p")}' "$f" || { echo "FAIL: prepend_block" >&2; exit 1; }
say "prepend_block coloca o bloco no topo"

write_env_sh "$tmp"
envf="${tmp}/.config/mac-dev-env/env.sh"
[[ -f "$envf" ]] || { echo "FAIL: write_env_sh não criou env.sh" >&2; exit 1; }
bash -n "$envf"
say "env.sh passa bash -n"
grep -Fq '/opt/homebrew' "$envf" || { echo "FAIL: env.sh sem /opt/homebrew" >&2; exit 1; }
grep -Fq '/usr/local' "$envf" || { echo "FAIL: env.sh sem /usr/local" >&2; exit 1; }
say "env.sh documenta Apple Silicon e Intel"
bash -c '. "$1"' _ "$envf" || { echo "FAIL: source env.sh" >&2; exit 1; }
say "source env.sh (sem brew) é seguro"

configure_shell_rc "$tmp"
for rc in .zprofile .zshrc .bash_profile .bashrc; do
  [[ -f "${tmp}/${rc}" ]] || { echo "FAIL: faltou $rc" >&2; exit 1; }
  grep -q 'mac-dev-env begin' "${tmp}/${rc}" || { echo "FAIL: $rc sem bloco marcado" >&2; exit 1; }
done
say "configure_shell_rc escreve zsh e bash com blocos marcados"

configure_shell_rc "$tmp"
n="$(grep -c 'mac-dev-env begin:zshrc ---' "${tmp}/.zshrc" || true)"
[[ "$n" -eq 1 ]] || { echo "FAIL: reexecução empilhou blocos zshrc (n=$n)" >&2; exit 1; }
say "reexecução de rc não empilha duplicatas"
grep -Fq 'history-search-backward' "${tmp}/.zshrc" || { echo "FAIL: zsh rc sem history-search" >&2; exit 1; }
say "zsh rc inclui history-search"

HERDR_KEYS="${ROOT}/guest/herdr-omarchy-keys.toml"
[[ -f "$HERDR_KEYS" ]] || { echo "FAIL: template Herdr ausente" >&2; exit 1; }
merge_herdr_keys "$tmp"
cfg="${tmp}/.config/herdr/config.toml"
grep -Fq 'prefix = "ctrl+space"' "$cfg" || { echo "FAIL: herdr keys não copiou prefix" >&2; exit 1; }
grep -Fq 'tokyo-night' "$cfg" || { echo "FAIL: herdr theme não semeado" >&2; exit 1; }
printf '\n[other]\nvalue = 1\n' >> "$cfg"
merge_herdr_keys "$tmp"
grep -Fq 'value = 1' "$cfg" || { echo "FAIL: merge apagou seção [other]" >&2; exit 1; }
n="$(grep -c 'prefix = "ctrl+space"' "$cfg" || true)"
[[ "$n" -eq 1 ]] || { echo "FAIL: merge duplicou [keys] (n=$n)" >&2; exit 1; }
say "merge_herdr_keys preserva outras seções e é idempotente"

brew_p="$(brew_prefix_guess)"
say "brew_prefix_guess=$brew_p"

merge_starship_config "$tmp"
star="${tmp}/.config/starship.toml"
grep -Fq 'Omarchy default starship prompt theme' "$star" || { echo "FAIL: starship tema não copiou" >&2; exit 1; }
grep -Fq 'tokyo-night' "$star" || { echo "FAIL: starship tema tokyo-night ausente" >&2; exit 1; }
grep -Eq '^\[username\]' "$star" || { echo "FAIL: starship tema faltando seções TOML" >&2; exit 1; }
grep -Fq 'mac-dev-env begin:starship' "$star" || { echo "FAIL: starship faltando block markers" >&2; exit 1; }
printf '\n[custom]\nvalue = 1\n' >> "$star"
merge_starship_config "$tmp"
grep -Fq 'value = 1' "$star" || { echo "FAIL: merge apagou seção [custom]" >&2; exit 1; }
n="$(grep -c 'Omarchy default starship prompt theme' "$star" || true)"
[[ "$n" -eq 1 ]] || { echo "FAIL: merge duplicou tema (n=$n)" >&2; exit 1; }
say "merge_starship_config embedded theme works and is idempotent"
HELPER
)" || {
  printf '%s\n' "$helper_out" >&2
  fail "subshell de helpers falhou"
  helper_out=""
}
if [[ -n "${helper_out}" ]]; then
  printf '%s\n' "$helper_out"
fi

if [[ "$FAILS" -ne 0 ]]; then
  printf '\n%s teste(s) falharam\n' "$FAILS" >&2
  exit 1
fi
printf '\nTodos os testes passaram.\n'
