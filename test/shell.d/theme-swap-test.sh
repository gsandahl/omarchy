#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

test_home="$test_tmp/home"
current_theme="$test_home/.local/state/omarchy/current/theme"
stub_bin="$test_tmp/bin"
mkdir -p "$test_home" "$test_tmp/runtime" "$stub_bin"

# Hyprland reloads the moment the old theme's hyprland.lua goes. Every mv is
# where the new theme moves in, so it notes whether a current theme exists
# right then and right after.
real_mv=$(command -v mv)
cat >"$stub_bin/mv" <<STUB
#!/bin/bash
[[ -e "$current_theme/hyprland.lua" ]] && echo "before present" >>"$test_tmp/mv.log" || echo "before missing" >>"$test_tmp/mv.log"
"$real_mv" "\$@"
status=\$?
[[ -e "$current_theme/hyprland.lua" ]] && echo "after present" >>"$test_tmp/mv.log" || echo "after missing" >>"$test_tmp/mv.log"
exit \$status
STUB
chmod +x "$stub_bin/mv"

set_theme() {
  HOME="$test_home" XDG_RUNTIME_DIR="$test_tmp/runtime" OMARCHY_PATH="$ROOT" PATH="$stub_bin:$ROOT/bin:$PATH" \
    OMARCHY_THEME_HEADLESS=1 "$ROOT/bin/omarchy-theme-set" "$1" >/dev/null
}

set_theme tokyo-night
: >"$test_tmp/mv.log"
set_theme catppuccin

grep -q '^catppuccin$' "$test_home/.local/state/omarchy/current/theme.name" || fail "the new theme is current"
accent=$(OMARCHY_PATH="$ROOT" "$ROOT/bin/omarchy-theme-color" --file "$ROOT/themes/catppuccin/colors.toml" accent)
grep -qF "$accent" "$current_theme/hyprland.lua" || fail "the new theme's hyprland.lua is in place" "$(head -5 "$current_theme/hyprland.lua")"
[[ ! -e $test_home/.local/state/omarchy/current/next-theme ]] || fail "the old theme does not linger as next-theme"
pass "switching themes replaces the current theme"

# The gapless swap needs mv --exchange, and the filesystem to support it.
mkdir "$test_tmp/exchange-a" "$test_tmp/exchange-b"
if mv --exchange -T "$test_tmp/exchange-a" "$test_tmp/exchange-b" 2>/dev/null; then
  ! grep -q 'missing' "$test_tmp/mv.log" || fail "a current theme exists at every point of the swap" "$(cat "$test_tmp/mv.log")"
  pass "switching themes never leaves the current theme missing"
else
  skip "switching themes never leaves the current theme missing: mv --exchange is unavailable"
fi
