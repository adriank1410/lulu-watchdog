#!/bin/zsh
#
# Test suite for lulu-watchdog.zsh. Runs sandboxed copies of the script with
# substituted paths — does not require LuLu to be installed or running, and
# never touches the real agent (uses a fake launchd label).
# Usage: zsh tests/test_watchdog.zsh

set -u

REPO_DIR="${0:A:h:h}"
SRC="$REPO_DIR/lulu-watchdog.zsh"
TDIR=$(mktemp -d /tmp/lulu-wd-test.XXXXXX)
trap '/bin/rm -rf "$TDIR"' EXIT

fail_count=0
pass() { print "PASS: $1" }
fail() { print "FAIL: $1"; fail_count=$(( fail_count + 1 )) }

# Fake LuLu.app bundle so [[ -d ]] and [[ -x ]] checks pass without LuLu
mkdir -p "$TDIR/FakeLuLu.app/Contents/MacOS"
print '#!/bin/zsh' > "$TDIR/FakeLuLu.app/Contents/MacOS/LuLu"
chmod +x "$TDIR/FakeLuLu.app/Contents/MacOS/LuLu"

# Deterministic "running process" for detection tests: a system sleep with a
# unique argument, matched via pgrep -f. (Copying /bin/sleep under a unique
# name does not work everywhere — sandboxed environments kill binaries
# executed from /tmp.)
/bin/sleep 29631 &
sleeper_pid=$!
trap '/bin/kill "$sleeper_pid" 2>/dev/null; /bin/rm -rf "$TDIR"' EXIT

base_seds=(
  -e "s,^app_path=.*,app_path=\"$TDIR/FakeLuLu.app\","
  -e "s,^log_file=.*,log_file=\"$TDIR/test.log\","
  -e "s,^state_dir=.*,state_dir=\"$TDIR\","
  -e 's,^agent_label=.*,agent_label="com.test.fake-lulu-watchdog",'
  -e 's,^notify_enabled=.*,notify_enabled=0,'
)
# Detection that never matches any real process
broken_detect=(
  -e 's,MacOS/LuLu( ,MacOS/LuLuZZZ( ,'
  -e 's,-x "LuLu",-x "LuLuZZZZZ",g'
)
# Detection that always matches (the sleeper started above)
match_detect=(
  -e 's,MacOS/LuLu( ,MacOS/LuLuZZZ( ,'
  -e 's,-x "LuLu",-f "sleep 29631",g'
)

mkcopy() {
  local out="$1"; shift
  sed "${base_seds[@]}" "$@" "$SRC" > "$out"
}

reset_sandbox() {
  # (N) null_glob qualifier: an empty glob must not abort the rm (zsh NOMATCH)
  /bin/rm -f "$TDIR/test.log" "$TDIR"/test.log.*(N) "$TDIR/app-missing-count" \
             "$TDIR/last-seen-running"
}

log_count() {
  grep -c "$1" "$TDIR/test.log" 2>/dev/null || true
}

# --- Test 0: syntax and plist lint -----------------------------------------
if zsh -n "$SRC" && zsh -n "$REPO_DIR/install.sh" && zsh -n "$REPO_DIR/uninstall.sh"; then
  pass "zsh -n syntax on all scripts"
else
  fail "zsh -n syntax on all scripts"
fi
if plutil -lint "$REPO_DIR/com.local.lulu-watchdog.plist" >/dev/null; then
  pass "plutil -lint plist"
else
  fail "plutil -lint plist"
fi

# --- Test 1: app missing -> counter, log-once, disable threshold -----------
reset_sandbox
mkcopy "$TDIR/t1.zsh" -e "s,^app_path=.*,app_path=\"$TDIR/NoSuchApp.app\"," \
                      -e 's,^max_app_missing_checks=.*,max_app_missing_checks=3,'
zsh "$TDIR/t1.zsh"; zsh "$TDIR/t1.zsh"; zsh "$TDIR/t1.zsh"
if [[ "$(cat "$TDIR/app-missing-count" 2>/dev/null)" == "3" ]] \
   && [[ "$(log_count 'missing at')" == "1" ]] \
   && [[ "$(log_count 'disabling watchdog')" == "1" ]]; then
  pass "missing app: counter=3, logged once, disable threshold logged once"
else
  fail "missing app: counter=3, logged once, disable threshold logged once"
fi

# --- Test 2: app back -> counter reset --------------------------------------
reset_sandbox
print "7" > "$TDIR/app-missing-count"
mkcopy "$TDIR/t2.zsh" "${match_detect[@]}"
zsh "$TDIR/t2.zsh"
if [[ ! -f "$TDIR/app-missing-count" ]] && [[ "$(log_count 'present again')" == "1" ]]; then
  pass "app present again: counter removed and reset logged"
else
  fail "app present again: counter removed and reset logged"
fi

# --- Test 3: open fails -> exit code logged ---------------------------------
reset_sandbox
mkcopy "$TDIR/t3.zsh" "${broken_detect[@]}" -e 's,^/usr/bin/open .*,/usr/bin/false,'
zsh "$TDIR/t3.zsh"
if [[ "$(log_count 'open failed (exit 1)')" == "1" ]]; then
  pass "open failure logged with exit code"
else
  fail "open failure logged with exit code"
fi

# --- Test 4: open ok but process never appears -> NOT confirmed -------------
reset_sandbox
mkcopy "$TDIR/t4.zsh" "${broken_detect[@]}" \
                      -e 's,^/usr/bin/open .*,/usr/bin/true,' \
                      -e 's,^launch_confirm_timeout=.*,launch_confirm_timeout=2,'
zsh "$TDIR/t4.zsh"
if [[ "$(log_count 'NOT confirmed within 2s')" == "1" ]]; then
  pass "relaunch timeout logged"
else
  fail "relaunch timeout logged"
fi

# --- Test 5: relaunch confirmed with PID ------------------------------------
reset_sandbox
mkcopy "$TDIR/t5.zsh" "${match_detect[@]}" \
                      -e 's,^lulu_running && .*,:,' \
                      -e 's,^/usr/bin/open .*,/usr/bin/true,'
zsh "$TDIR/t5.zsh"
if grep -Eq 'relaunch confirmed after [0-9]+s \(PID [0-9]+\)' "$TDIR/test.log"; then
  pass "relaunch confirmed with PID"
else
  fail "relaunch confirmed with PID"
fi

# --- Test 5b: fresh seen-marker -> notification branch taken ----------------
reset_sandbox
: > "$TDIR/last-seen-running"
zsh "$TDIR/t5.zsh"
if grep -q 'relaunch confirmed' "$TDIR/test.log" \
   && ! grep -q 'notification suppressed' "$TDIR/test.log"; then
  pass "fresh marker: notification branch taken (not suppressed)"
else
  fail "fresh marker: notification branch taken (not suppressed)"
fi

# --- Test 5c: stale/no seen-marker -> notification suppressed ---------------
reset_sandbox
zsh "$TDIR/t5.zsh"
if grep -q 'notification suppressed' "$TDIR/test.log"; then
  pass "no marker: notification suppressed"
else
  fail "no marker: notification suppressed"
fi

# --- Test 6: log rotation ----------------------------------------------------
reset_sandbox
print "7" > "$TDIR/app-missing-count"
/usr/bin/head -c 200 /dev/zero | tr '\0' 'x' > "$TDIR/test.log"
mkcopy "$TDIR/t6.zsh" "${match_detect[@]}" -e 's,^max_log_bytes=.*,max_log_bytes=100,'
zsh "$TDIR/t6.zsh"
if [[ -f "$TDIR/test.log.1" ]] && [[ "$(log_count 'present again')" == "1" ]]; then
  pass "log rotation at size threshold"
else
  fail "log rotation at size threshold"
fi

# --- Test 7: plist __HOME__ substitution ------------------------------------
sed "s|__HOME__|/Users/testuser|g" "$REPO_DIR/com.local.lulu-watchdog.plist" > "$TDIR/sub.plist"
if ! grep -q '__HOME__' "$TDIR/sub.plist" \
   && grep -q '/Users/testuser/Library/Application Support' "$TDIR/sub.plist" \
   && plutil -lint "$TDIR/sub.plist" >/dev/null; then
  pass "plist placeholder substitution"
else
  fail "plist placeholder substitution"
fi

print ""
if (( fail_count == 0 )); then
  print "All tests passed."
else
  print "${fail_count} test(s) FAILED."
  exit 1
fi
