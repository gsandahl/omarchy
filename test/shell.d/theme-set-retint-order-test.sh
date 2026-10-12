#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'touch "$test_tmp/release" "$test_tmp/intro-done"; kill "${hypr_events_pid:-}" 2>/dev/null; rm -rf "$test_tmp"' EXIT
home="$test_tmp/home"
state="$home/.local/state/omarchy/current"
themes="$home/.config/omarchy/themes"
commands="$test_tmp/bin"
log="$test_tmp/commands"
mkdir -p "$state" "$commands" "$home/.local/state/omarchy/theme-backgrounds"
for theme in alpha beta; do
  mkdir -p "$themes/$theme/backgrounds/intros"
  cp "$ROOT/themes/tokyo-night/colors.toml" "$themes/$theme/colors.toml"
  printf 'still\n' >"$themes/$theme/backgrounds/1-sky.webp"
  printf -- '-- borders\n' >"$themes/$theme/hyprland.lua"
  printf 'intro\n' >"$themes/$theme/backgrounds/intros/1-sky.mp4"
done
cp -r "$themes/alpha" "$state/theme"
printf 'alpha\n' >"$state/theme.name"
ln -s "$state/theme/backgrounds/1-sky.webp" "$state/background"

# Every retint logs its name. The browser one reads the theme when it starts,
# as the real one reads its colour, logs it when it finishes, and holds until
# released, standing in for a slow policy write; with TEST_HOLD_THEME it holds
# only once, for that theme. The VS Code one fails.
cat >"$commands/retint" <<'STUB'
#!/bin/bash
name=${0##*/}
if [[ $name == omarchy-theme-set-browser ]]; then
  theme=$(<"$TEST_STATE/theme.name")
  if [[ -z ${TEST_HOLD_THEME:-} || ($theme == "$TEST_HOLD_THEME" && ! -f $TEST_TMP/held) ]]; then
    touch "$TEST_TMP/held"
    for attempt in {1..250}; do
      [[ ! -f $TEST_TMP/release ]] || break
      sleep 0.02
    done
  fi
  echo "browser-for $theme" >>"$TEST_LOG"
  # The real one hands its stdin to the policy writer, which prompts there.
  if [[ -n ${TEST_READ_STDIN:-} ]] && read -r -t 1 line; then
    echo "browser-stdin $line" >>"$TEST_LOG"
  fi
fi
# An explicit Hyprland reload takes TEST_RELOAD_SECONDS and then shows up on
# the event socket.
if [[ $name == omarchy-restart-hyprctl ]]; then
  sleep "${TEST_RELOAD_SECONDS:-0}"
  echo reload >>"$TEST_TMP/explicit-reloads"
fi
echo "$name" >>"$TEST_LOG"
if [[ $name == omarchy-restart-hyprctl && -n ${TEST_RELOAD_FAILS:-} ]]; then
  exit 1
fi
# With TEST_SLOW_HOOK_THEME, that theme's hook writes to stderr only once the
# test says a later batch is done.
if [[ $name == omarchy-hook && -n ${TEST_SLOW_HOOK_THEME:-} && $2 == "$TEST_SLOW_HOOK_THEME" ]]; then
  touch "$TEST_TMP/slow-hook-started"
  for attempt in {1..250}; do
    [[ ! -f $TEST_TMP/later-batch-done ]] || break
    sleep 0.02
  done
  echo "late output from the $2 hook" >&2
fi
# With TEST_HOOK_SWITCH, the theme-set hook switches to that theme itself.
if [[ $name == omarchy-hook && -n ${TEST_HOOK_SWITCH:-} && $2 != "$TEST_HOOK_SWITCH" ]]; then
  OMARCHY_THEME_WAIT=1 /bin/bash "$TEST_ROOT/bin/omarchy-theme-set" "$TEST_HOOK_SWITCH" </dev/null >/dev/null 2>&1
fi
# The VS Code retint fails, except for TEST_VSCODE_OK_THEME.
[[ $name != omarchy-theme-set-vscode || $(<"$TEST_STATE/theme.name") == "${TEST_VSCODE_OK_THEME:-}" ]]
STUB
cat >"$commands/noop" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$commands/retint" "$commands/noop"
for command in "$ROOT"/bin/omarchy-restart-* "$ROOT"/bin/omarchy-theme-set-* omarchy-hook omarchy-theme-bg-cache; do
  ln -sf retint "$commands/${command##*/}"
done
for command in omarchy-theme-set-templates omarchy-theme-set-herdr-machines; do
  ln -sf noop "$commands/$command"
done
cat >"$commands/omarchy-notification-send" <<'STUB'
#!/bin/bash
echo "notify: $*" >>"$TEST_LOG"
STUB
# Hyprland's own config watch is off unless a case turns it on.
cat >"$commands/hyprctl" <<'STUB'
#!/bin/bash
if [[ $3 == "misc:disable_autoreload" ]]; then
  printf '{"bool":%s}\n' "${TEST_AUTORELOAD_OFF:-true}"
else
  printf '{"bool":true}\n'
fi
STUB
# The new theme's intro stays on screen until the test lets it finish. While
# $TEST_TMP/intro-hold exists, beta's intro keeps playing even after another
# theme replaced it.
cat >"$commands/omarchy-shell" <<'STUB'
#!/bin/bash
if [[ $2 == "themeIntroStatus" && -f $TEST_TMP/intro-hold ]]; then
  if [[ $(<"$TEST_STATE/theme.name") == "beta" && $3 == "$(stat -Lc '%d:%i' "$TEST_STATE/theme")" ]]; then
    echo "$3" >"$TEST_TMP/intro-hold"
  fi
  if [[ $3 == "$(<"$TEST_TMP/intro-hold")" ]]; then
    echo "pending"
  else
    echo "ready"
  fi
elif [[ $2 == "themeIntroStatus" && $(<"$TEST_STATE/theme.name") == "beta" && ! -f $TEST_TMP/intro-done ]]; then
  echo "pending"
else
  echo "ready"
fi
STUB
# With TEST_INTRO_SECONDS, an intro plays for that long.
cat >"$commands/owe" <<'STUB'
#!/bin/bash
if [[ $1 == "intro" && -n ${TEST_INTRO_SECONDS:-} ]]; then
  sleep "$TEST_INTRO_SECONDS"
fi
[[ $1 != "render" ]]
STUB
# With TEST_NO_EXCHANGE, mv stands in for one without --exchange.
real_mv=$(command -v mv)
cat >"$commands/mv" <<STUB
#!/bin/bash
if [[ \$1 == "--exchange" && -n \${TEST_NO_EXCHANGE:-} ]]; then
  exit 1
fi
exec "$real_mv" "\$@"
STUB
chmod +x "$commands/omarchy-notification-send" "$commands/hyprctl" "$commands/omarchy-shell" "$commands/owe" "$commands/mv"

# Hyprland's event socket. While $TEST_TMP/hyprland-autoreloads exists, it
# reports a config reload once the swap has replaced the current theme, which
# the test marks with an outgoing-theme file beforehand. It also reports each
# explicit reload made after the listener connected.
export TEST_TMP="$test_tmp" TEST_STATE="$state"
mkdir -p "$test_tmp/hypr/test-hypr"
: >"$test_tmp/explicit-reloads"
cat >"$test_tmp/hypr-events" <<'STUB'
#!/bin/bash
explicit=$(wc -l <"$TEST_TMP/explicit-reloads")
for attempt in {1..300}; do
  if [[ -f $TEST_TMP/hyprland-autoreloads && ! -e $TEST_STATE/theme/outgoing-theme && -e $TEST_STATE/theme/hyprland.lua ]] ||
    (( $(wc -l <"$TEST_TMP/explicit-reloads") > explicit )); then
    echo "configreloaded>>"
    break
  fi
  sleep 0.01
done
sleep 3
STUB
chmod +x "$test_tmp/hypr-events"
socat "UNIX-LISTEN:$test_tmp/hypr/test-hypr/.socket2.sock,fork" "EXEC:$test_tmp/hypr-events" 2>/dev/null &
hypr_events_pid=$!
for attempt in {1..100}; do
  [[ ! -S $test_tmp/hypr/test-hypr/.socket2.sock ]] || break
  sleep 0.02
done

set_theme() {
  : >"$log"
  switch_theme "$@"
}

switch_theme() {
  HOME="$home" OMARCHY_PATH="$ROOT" PATH="$commands:$ROOT/bin:$PATH" XDG_RUNTIME_DIR="$test_tmp" HYPRLAND_INSTANCE_SIGNATURE=test-hypr \
    TEST_LOG="$log" TEST_TMP="$test_tmp" TEST_STATE="$state" TEST_ROOT="$ROOT" \
    /bin/bash "$ROOT/bin/omarchy-theme-set" "$1" </dev/null >"$test_tmp/stdout" 2>"$test_tmp/stderr" ||
    fail "theme selection completes" "$(cat "$test_tmp/stderr")"
}

# The held browser retint has started, so its batch holds the retints.
wait_held() {
  for attempt in {1..250}; do
    [[ ! -f $test_tmp/held ]] || return 0
    sleep 0.02
  done
  fail "the held browser retint starts"
}

wait_logged() {
  for attempt in {1..250}; do
    grep -q "$1" "$log" && return 0
    sleep 0.02
  done
  fail "$2" "$(cat "$log")"
}

wait_for_detached_work() {
  for attempt in {1..250}; do
    pgrep -f "^/bin/bash $ROOT/bin/omarchy-theme-set (alpha|beta)\$" >/dev/null || return 0
    sleep 0.02
  done
  fail "the detached retints finish"
}

set_theme beta
for command in omarchy-restart-terminal omarchy-theme-set-foot omarchy-theme-set-tmux omarchy-restart-btop; do
  grep -qx "$command" "$log" || fail "$command retints before the switch returns, while the intro plays" "$(cat "$log")"
done
! grep -qx 'omarchy-theme-set-gnome' "$log" || fail "other apps wait for the intro to finish its reveal"
! grep -qx 'omarchy-theme-bg-cache' "$log" || fail "thumbnail warmup waits for the intro to finish its reveal"
! grep -qx 'omarchy-hook' "$log" || fail "the theme-set hook waits for the other retints"
touch "$test_tmp/intro-done"
wait_logged '^omarchy-theme-set-gnome$' "other apps retint once the intro has revealed"
wait_logged '^omarchy-theme-bg-cache$' "thumbnail warmup starts once the intro has revealed"
! grep -qx 'omarchy-theme-set-browser' "$log" || fail "the held browser retint is still running"
touch "$test_tmp/release"
wait_logged '^omarchy-hook$' "the theme-set hook runs after the other retints"
wait_logged '^notify: .*omarchy-theme-set-vscode failed' "a failed detached retint is reported in a notification"
wait_for_detached_work
grep -q 'Theme retint failed: omarchy-theme-set-vscode' "$home/.local/state/omarchy/theme-set.log" ||
  fail "a failed detached retint is named in the theme-set log"
pass "terminals retint during an intro and the other apps follow without holding up the switch"

rm -f "$test_tmp/release"
OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
grep -qx 'omarchy-restart-hyprctl' "$log" || fail "a switch without an intro reloads Hyprland before returning"
! grep -qx 'omarchy-theme-set-browser' "$log" || fail "the browser retint does not hold up the switch"
touch "$test_tmp/release"
wait_for_detached_work
pass "a switch without an intro reloads Hyprland with the terminals"

# Hyprland reloading by itself after the swap leaves it at that one reload.
mkdir "$test_tmp/exchange-a" "$test_tmp/exchange-b"
if mv --exchange -T "$test_tmp/exchange-a" "$test_tmp/exchange-b" 2>/dev/null; then
  rm -f "$test_tmp/release"
  touch "$test_tmp/hyprland-autoreloads" "$state/theme/outgoing-theme"
  TEST_AUTORELOAD_OFF=false OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
  rm -f "$test_tmp/hyprland-autoreloads"
  ! grep -qx 'omarchy-restart-hyprctl' "$log" || fail "a reload Hyprland made by itself after the swap is not repeated"
  touch "$test_tmp/release"
  wait_for_detached_work
  pass "Hyprland reloads only once when its config watch caught the swap"
else
  skip "Hyprland reloads only once when its config watch caught the swap: mv --exchange is unavailable"
fi

# The watch is on, but no reload follows the swap: the explicit one still runs.
rm -f "$test_tmp/release"
TEST_AUTORELOAD_OFF=false OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
grep -qx 'omarchy-restart-hyprctl' "$log" || fail "a swap no reload followed reloads Hyprland"
# Waiting out the watch must not hold the terminals back.
(( $(grep -nx 'omarchy-restart-terminal' "$log" | cut -d: -f1) < $(grep -nx 'omarchy-restart-hyprctl' "$log" | cut -d: -f1) )) ||
  fail "the terminals retint while the Hyprland reload is settled" "$(cat "$log")"
touch "$test_tmp/release"
wait_for_detached_work
! pgrep -f "socat -u UNIX-CONNECT:$test_tmp/" >/dev/null || fail "the switch stops listening to Hyprland's events when done"
! compgen -G "$test_tmp/omarchy-theme-set-events.*" >/dev/null || fail "the switch removes its record of Hyprland's events"
pass "a swap the config watch missed still reloads Hyprland, after the terminals and cleaning up"

# Bash writes EPOCHREALTIME with the locale's decimal separator, a comma in
# da_DK and most of Europe. Build such a locale here, when localedef can.
mkdir -p "$test_tmp/locales"
if localedef -i da_DK -f UTF-8 "$test_tmp/locales/da_DK.UTF-8" >/dev/null 2>&1; then
  now=$(LOCPATH="$test_tmp/locales" LC_ALL=da_DK.UTF-8 bash -c '
    source <(awk "/^now_us\\(\\) \\{/ { copying=1 } copying { print } copying && /^}\$/ { exit }" "$1")
    now_us
    echo "$REPLY"
  ' _ "$ROOT/bin/omarchy-theme-set")
  [[ $now =~ ^[0-9]{16}$ ]] || fail "the switch's microsecond clock reads digits under a comma locale" "$now"
  rm -f "$test_tmp/release"
  touch "$test_tmp/release"
  (
    # This shell cannot load the locale itself; theme-set, started with LOCPATH, can.
    export LOCPATH="$test_tmp/locales"
    export LC_ALL=da_DK.UTF-8 2>/dev/null
    TEST_AUTORELOAD_OFF=false OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
  ) || fail "a comma-locale switch completes"
  grep -qx 'omarchy-restart-hyprctl' "$log" || fail "a comma-locale switch no reload followed reloads Hyprland"
  grep -qx 'omarchy-hook' "$log" || wait_logged '^omarchy-hook$' "a comma-locale switch runs through to its hook"
  wait_for_detached_work
  pass "a switch under a comma-decimal locale settles the Hyprland reload"
else
  skip "a switch under a comma-decimal locale settles the Hyprland reload: localedef cannot build da_DK"
fi

# A failed explicit reload is reported like any retint.
rm -f "$test_tmp/release"
touch "$test_tmp/release"
TEST_RELOAD_FAILS=1 OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
wait_logged '^notify: .*omarchy-restart-hyprctl' "a failed Hyprland reload is reported"
wait_for_detached_work
pass "a failed Hyprland reload is reported"

# An intro defers the explicit reload until after playback, long after the
# reload Hyprland made by itself at the swap, which still counts.
if mv --exchange -T "$test_tmp/exchange-a" "$test_tmp/exchange-b" 2>/dev/null; then
  rm -f "$test_tmp/release"
  touch "$test_tmp/release" "$test_tmp/intro-done"
  OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
  wait_for_detached_work
  touch "$test_tmp/hyprland-autoreloads" "$state/theme/outgoing-theme"
  TEST_INTRO_SECONDS=0.8 TEST_AUTORELOAD_OFF=false set_theme beta
  wait_for_detached_work
  rm -f "$test_tmp/hyprland-autoreloads"
  grep -q '^omarchy-theme-set-gnome$' "$log" || fail "the intro switch finishes its retints"
  ! grep -qx 'omarchy-restart-hyprctl' "$log" || fail "an intro does not repeat the reload Hyprland made at the swap"
  pass "an intro does not repeat the reload Hyprland made at the swap"

  # Alpha's slow explicit reload must not reach beta's listener after beta's
  # swap, where it would pass for a reload of beta.
  : >"$log"
  touch "$test_tmp/release"
  TEST_RELOAD_SECONDS=0.3 OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme alpha &
  alpha_switch=$!
  sleep 0.1
  TEST_AUTORELOAD_OFF=false OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme beta
  wait "$alpha_switch"
  wait_for_detached_work
  (( $(grep -cx 'omarchy-restart-hyprctl' "$log") == 2 )) ||
    fail "a reload from the previous switch does not count for the next one" "$(cat "$log")"
  pass "a reload from the previous switch does not count for the next one"
else
  skip "an intro does not repeat the reload Hyprland made at the swap: mv --exchange is unavailable"
fi

# Without an exchanging rename the swap leaves a gap, and a reload that lands
# in it may have loaded no theme, so it does not count.
rm -f "$test_tmp/release"
touch "$test_tmp/hyprland-autoreloads" "$state/theme/outgoing-theme"
TEST_NO_EXCHANGE=1 TEST_AUTORELOAD_OFF=false OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
rm -f "$test_tmp/hyprland-autoreloads"
grep -qx 'omarchy-restart-hyprctl' "$log" || fail "a swap that could not be one rename reloads Hyprland"
[[ $(<"$state/theme.name") == "beta" && -f $state/theme/hyprland.lua ]] || fail "the fallback swap still applies the theme"
touch "$test_tmp/release"
wait_for_detached_work
pass "a swap that could not be one rename still reloads Hyprland"

rm -f "$test_tmp/release"
(sleep 0.3; touch "$test_tmp/release") &
releaser=$!
OMARCHY_THEME_WAIT=1 OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme beta
wait "$releaser"
for command in omarchy-theme-set-browser omarchy-hook; do
  grep -qx "$command" "$log" || fail "OMARCHY_THEME_WAIT=1 returns only after $command" "$(cat "$log")"
done
grep -q 'Theme retint failed: omarchy-theme-set-vscode' "$test_tmp/stderr" || fail "a waited-for failure is named on stderr"
! grep -q '^notify: ' "$log" || fail "a waited-for failure is not also a notification"
pass "OMARCHY_THEME_WAIT=1 waits for every retint and reports failures on stderr"

# Alpha's browser retint is slow. Beta, picked meanwhile, must not finish first
# and then be overwritten by alpha's late write.
rm -f "$test_tmp/release" "$test_tmp/held"
TEST_HOLD_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
wait_held
(sleep 0.3; touch "$test_tmp/release") &
releaser=$!
TEST_HOLD_THEME=alpha OMARCHY_THEME_WAIT=1 OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme beta
wait "$releaser"
wait_for_detached_work
[[ $(grep '^browser-for ' "$log" | tr '\n' ' ') == "browser-for alpha browser-for beta " ]] ||
  fail "an older switch's retints finish before a newer one's start" "$(cat "$log")"
pass "retint batches from quick switches run in order"

# Beta and then alpha are picked while alpha's first batch holds the retints.
# Beta's batch finds its theme already replaced and leaves the apps alone.
rm -f "$test_tmp/release" "$test_tmp/held"
TEST_HOLD_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
wait_held
TEST_HOLD_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme beta
TEST_HOLD_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme alpha
touch "$test_tmp/release"
wait_for_detached_work
[[ $(grep '^browser-for ' "$log" | tr '\n' ' ') == "browser-for alpha browser-for alpha " ]] ||
  fail "a batch whose theme was replaced while it waited skips its retints" "$(cat "$log")"
(( $(grep -cx 'omarchy-hook' "$log") == 3 )) || fail "every switch still runs the theme-set hook" "$(cat "$log")"
pass "a superseded retint batch leaves the apps to the newer theme"

# A theme-set hook that switches the theme waits for that switch's retints,
# which must not wait in turn for the batch that ran the hook.
rm -f "$test_tmp/release" "$test_tmp/held"
touch "$test_tmp/release"
TEST_HOOK_SWITCH=beta OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
for attempt in {1..250}; do
  (( $(grep -cx 'omarchy-hook' "$log") >= 2 )) && break
  sleep 0.02
done
wait_for_detached_work
[[ $(<"$state/theme.name") == "beta" ]] || fail "the hook's switch applies"
grep -qx 'browser-for beta' "$log" || fail "a switch made from a theme-set hook runs its retints" "$(cat "$log")"
pass "a theme-set hook can switch the theme without deadlocking the retints"

# Alpha's hook is still running when beta's batch starts the log over; its
# late output must not write over what beta's batch reported.
rm -f "$test_tmp/held" "$test_tmp/slow-hook-started" "$test_tmp/later-batch-done"
touch "$test_tmp/release"
TEST_VSCODE_OK_THEME=alpha TEST_SLOW_HOOK_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
for attempt in {1..250}; do
  [[ ! -f $test_tmp/slow-hook-started ]] || break
  sleep 0.02
done
TEST_VSCODE_OK_THEME=alpha TEST_SLOW_HOOK_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme beta
for attempt in {1..250}; do
  (( $(grep -c '^notify: ' "$log") >= 1 )) && break
  sleep 0.02
done
touch "$test_tmp/later-batch-done"
wait_for_detached_work
grep -qx 'Theme retint failed: omarchy-theme-set-vscode' "$home/.local/state/omarchy/theme-set.log" ||
  fail "an older batch's late output leaves the newer batch's report intact" "$(cat "$home/.local/state/omarchy/theme-set.log")"
grep -qx 'late output from the alpha hook' "$home/.local/state/omarchy/theme-set.log" ||
  fail "an older batch's late output is still logged" "$(cat "$home/.local/state/omarchy/theme-set.log")"
pass "overlapping batches append to the theme-set log"

# Beta's batch waits out its intro while alpha is picked and alpha's batch
# reports a failure. Beta's batch, superseded, must leave alpha's report in the
# log the notification points to.
rm -f "$test_tmp/release" "$test_tmp/held" "$test_tmp/intro-done"
touch "$test_tmp/release"
OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
wait_for_detached_work
touch "$test_tmp/intro-hold"
set_theme beta
for attempt in {1..250}; do
  [[ ! -s $test_tmp/intro-hold ]] || break
  sleep 0.02
done
[[ -s $test_tmp/intro-hold ]] || fail "beta's batch waits for its intro"
OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme alpha
wait_logged '^notify: ' "alpha's batch reports its failure"
rm -f "$test_tmp/intro-hold"
wait_for_detached_work
grep -qx 'Theme retint failed: omarchy-theme-set-vscode' "$home/.local/state/omarchy/theme-set.log" ||
  fail "a superseded batch leaves the newer batch's report in the log" "$(cat "$home/.local/state/omarchy/theme-set.log")"
(( $(grep -c '^browser-for ' "$log") == 1 )) || fail "only alpha's batch retints" "$(cat "$log")"
pass "a superseded batch leaves the theme-set log to the newer one"

# A switch that waits hands its stdin to the retints, so the browser policy
# can prompt on the terminal the switch was typed in.
rm -f "$test_tmp/held"
touch "$test_tmp/release"
: >"$log"
printf 'typed-password\n' |
  HOME="$home" OMARCHY_PATH="$ROOT" PATH="$commands:$ROOT/bin:$PATH" XDG_RUNTIME_DIR="$test_tmp" \
    TEST_LOG="$log" TEST_TMP="$test_tmp" TEST_STATE="$state" TEST_ROOT="$ROOT" TEST_READ_STDIN=1 \
    OMARCHY_THEME_WAIT=1 OMARCHY_THEME_SKIP_BACKGROUND=1 /bin/bash "$ROOT/bin/omarchy-theme-set" alpha >/dev/null 2>&1
grep -qx 'browser-stdin typed-password' "$log" || fail "a waited-for retint reads the switch's stdin" "$(cat "$log")"
pass "a waited-for switch gives the retints its stdin"

# Alpha's VS Code retint fails, but beta replaces alpha during alpha's hook and
# applies cleanly. Alpha's stale failure is not reported against beta.
rm -f "$test_tmp/held" "$test_tmp/slow-hook-started" "$test_tmp/later-batch-done"
touch "$test_tmp/release"
TEST_VSCODE_OK_THEME=beta TEST_SLOW_HOOK_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
for attempt in {1..250}; do
  [[ ! -f $test_tmp/slow-hook-started ]] || break
  sleep 0.02
done
TEST_VSCODE_OK_THEME=beta TEST_SLOW_HOOK_THEME=alpha OMARCHY_THEME_SKIP_BACKGROUND=1 switch_theme beta
for attempt in {1..250}; do
  (( $(grep -cx 'omarchy-hook' "$log") >= 2 )) && break
  sleep 0.02
done
touch "$test_tmp/later-batch-done"
wait_for_detached_work
! grep -q '^notify: ' "$log" || fail "a superseded batch does not report its failures" "$(cat "$log")"
! grep -q 'Theme retint failed' "$home/.local/state/omarchy/theme-set.log" ||
  fail "a superseded batch's failure stays out of the newer switch's log" "$(cat "$home/.local/state/omarchy/theme-set.log")"
pass "a superseded batch does not report failures against the newer theme"

# A switch that cannot write its token still retints the other apps.
rm -f "$test_tmp/release" "$state/theme.generation"
touch "$test_tmp/release"
mkdir "$state/theme.generation"
OMARCHY_THEME_SKIP_BACKGROUND=1 set_theme alpha
wait_logged '^omarchy-theme-set-gnome$' "other apps retint when the switch token cannot be written"
wait_for_detached_work
rmdir "$state/theme.generation"
pass "a switch whose token cannot be written still retints the other apps"
