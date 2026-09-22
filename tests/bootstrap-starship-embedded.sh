#!/usr/bin/env bash
# Test that guest/bootstrap.sh has embedded starship theme and doesn't require external files
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${ROOT}/guest/bootstrap.sh"
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

# Test that merge_starship_config works without external files
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

# Create an isolated environment to test merge_starship_config
# We need to source the script's functions but not execute it
(
  cd "$TESTDIR"
  
  # Extract just the functions we need from bootstrap.sh without executing the main script
  # We'll mock USER_NAME since merge_starship_config checks it
  export USER_NAME="testuser"
  
  # Create a minimal script that sources the functions
  cat > test_merge.sh <<'TESTSCRIPT'
set -euo pipefail

# Source the block markers and helper functions from bootstrap.sh
BEGIN_STARSHIP="# --- wsl-dev-env begin:starship ---"
END_STARSHIP="# --- wsl-dev-env end:starship ---"

append_block() {
  local file="$1" begin="$2" end="$3" body="$4"
  if ! grep -Fq "$begin" "$file"; then
    printf '\n%s\n%s\n%s\n' "$begin" "$body" "$end" >> "$file"
  else
    local tmp
    tmp="$(mktemp)"
    awk -v begin="$begin" -v end="$end" -v body="$body" '
      BEGIN { skip=0; done=0 }
      {
        line=$0
        t=line
        sub(/\r$/, "", t)
      }
      t==begin { print; print body; skip=1; done=1; next }
      t==end { skip=0; next }
      skip==0 { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
  fi
}

strip_block() {
  local file="$1" begin="$2" end="$3"
  if ! grep -Fq "$begin" "$file"; then
    return 0
  fi
  local tmp
  tmp="$(mktemp)"
  awk -v begin="$begin" -v end="$end" '
    BEGIN { skip=0 }
    {
      line=$0
      t=line
      sub(/\r$/, "", t)
    }
    t==begin { skip=1; next }
    t==end { skip=0; next }
    skip==0 { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

# Source merge_starship_config from bootstrap.sh
# We extract it by reading between the function definition lines
TESTSCRIPT

  # Mock the ok() function that merge_starship_config calls
  cat >> test_merge.sh <<'MOCK'
ok() { :; }  # no-op for testing
MOCK

  # Extract the merge_starship_config function
  sed -n '/^merge_starship_config() {$/,/^}$/p' "$SCRIPT" >> test_merge.sh
  
  # Add a test call
  cat >> test_merge.sh <<'TESTCALL'

# Test with a fake home directory
merge_starship_config "."
TESTCALL

  bash test_merge.sh 2>&1
  exitcode=$?
  
  if [[ $exitcode -eq 0 ]]; then
    printf 'ok - merge_starship_config executed without errors\n'
  else
    printf 'FAIL: merge_starship_config failed with exit code %d\n' "$exitcode" >&2
    exit 1
  fi
  
  if [[ -f .config/starship.toml ]]; then
    printf 'ok - starship.toml created\n'
  else
    printf 'FAIL: starship.toml not created\n' >&2
    exit 1
  fi
  
  # Verify the content includes the Omarchy theme markers
  if grep -q "Omarchy default starship prompt theme" .config/starship.toml; then
    printf 'ok - starship.toml contains Omarchy theme\n'
  else
    printf 'FAIL: starship.toml missing Omarchy theme content\n' >&2
    exit 1
  fi
  
  if grep -q "tokyo-night" .config/starship.toml; then
    printf 'ok - starship.toml contains tokyo-night theme\n'
  else
    printf 'FAIL: starship.toml missing tokyo-night reference\n' >&2
    exit 1
  fi
  
  # Verify it has TOML sections
  if grep -qE '^\[username\]' .config/starship.toml && \
     grep -qE '^\[directory\]' .config/starship.toml && \
     grep -qE '^\[git_branch\]' .config/starship.toml; then
    printf 'ok - starship.toml has expected TOML sections\n'
  else
    printf 'FAIL: starship.toml missing expected TOML sections\n' >&2
    exit 1
  fi
  
  # Verify the wsl-dev-env block markers are present
  if grep -q "wsl-dev-env begin:starship" .config/starship.toml && \
     grep -q "wsl-dev-env end:starship" .config/starship.toml; then
    printf 'ok - starship.toml has wsl-dev-env block markers\n'
  else
    printf 'FAIL: starship.toml missing block markers\n' >&2
    exit 1
  fi
)

subtest_exit=$?
if [[ $subtest_exit -eq 0 ]]; then
  pass "merge_starship_config works without guest/starship-omarchy.toml"
else
  fail "merge_starship_config failed (see output above)"
  FAILS=$((FAILS + 1))
fi

# Test that the embedded content matches the source file
TMPEMBED="$(mktemp)"
sed -n '/body="$(cat <<'\''STARSHIP_THEME_EOF'\''/,/^STARSHIP_THEME_EOF$/p' "$SCRIPT" | sed '1d;$d' > "$TMPEMBED"
if diff -q "${ROOT}/guest/starship-omarchy.toml" "$TMPEMBED" >/dev/null 2>&1; then
  pass "embedded content matches guest/starship-omarchy.toml"
else
  fail "embedded content differs from guest/starship-omarchy.toml"
fi
rm -f "$TMPEMBED"

if [[ $FAILS -eq 0 ]]; then
  echo
  echo "All tests passed!"
  exit 0
else
  echo
  echo "$FAILS test(s) failed"
  exit 1
fi
