#!/usr/bin/env bash
# Test that guest/bootstrap.sh writes the embedded starship config without external files
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/guest/bootstrap.sh"
SHIPPED="${ROOT}/guest/starship-omarchy.toml"
FAILS=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  FAILS=$((FAILS + 1))
}

pass() {
  printf 'ok - %s\n' "$*"
}

[[ -f "$SCRIPT" ]] || { echo "script ausente: $SCRIPT" >&2; exit 1; }

bash -n "$SCRIPT"
pass "bash -n guest/bootstrap.sh"

TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# bootstrap.sh runs on source, so load only merge_starship_config into a harness
HARNESS="${TESTDIR}/harness.sh"
{
  printf 'set -euo pipefail\n'
  printf 'USER_NAME="$(id -un)"\n'
  printf 'ok() { printf "    %%s\\n" "$*"; }\n'
  sed -n '/^merge_starship_config() {$/,/^}$/p' "$SCRIPT"
  printf 'merge_starship_config "$1"\n'
} > "$HARNESS"

HOME_EMPTY="${TESTDIR}/empty"
mkdir -p "$HOME_EMPTY"
if bash "$HARNESS" "$HOME_EMPTY" >/dev/null; then
  pass "merge_starship_config roda sem guest/starship-omarchy.toml"
else
  fail "merge_starship_config falhou em home vazio"
fi
if cmp -s "$SHIPPED" "${HOME_EMPTY}/.config/starship.toml"; then
  pass "starship.toml gerado é idêntico a guest/starship-omarchy.toml"
else
  fail "starship.toml gerado difere de guest/starship-omarchy.toml"
fi

HOME_OLD="${TESTDIR}/old"
mkdir -p "${HOME_OLD}/.config"
star="${HOME_OLD}/.config/starship.toml"
printf 'add_newline = false\n\n[custom]\nvalue = 1\n' > "$star"
out="$(bash "$HARNESS" "$HOME_OLD")"
backups=("${star}".bak.*)
if [[ ${#backups[@]} -eq 1 && -f "${backups[0]}" ]] && grep -Fxq 'value = 1' "${backups[0]}"; then
  pass "starship.toml divergente foi salvo em backup"
else
  fail "backup do starship.toml divergente ausente"
fi
if printf '%s' "$out" | grep -Fq "${backups[0]}"; then
  pass "mensagem informa o caminho do backup"
else
  fail "mensagem não informa o backup: $out"
fi
if cmp -s "$SHIPPED" "$star"; then
  pass "starship.toml divergente foi substituído pelo config enviado"
else
  fail "starship.toml divergente não foi substituído"
fi

touch -t 200001010000 "$star"
bash "$HARNESS" "$HOME_OLD" >/dev/null
backups=("${star}".bak.*)
if [[ ${#backups[@]} -eq 1 ]] && cmp -s "$SHIPPED" "$star" && [[ -z "$(find "$star" -newermt 2001-01-01)" ]]; then
  pass "reexecução com config igual não reescreve nem cria backup"
else
  fail "reexecução alterou starship.toml ou criou backup extra"
fi

if [[ $FAILS -eq 0 ]]; then
  echo
  echo "All tests passed!"
  exit 0
else
  echo
  echo "$FAILS test(s) failed"
  exit 1
fi
