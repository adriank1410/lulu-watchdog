#!/bin/zsh
#
# Test suite for lulu-watchdog.zsh. Runs sandboxed copies of the script with
# substituted paths — does not require LuLu to be installed or running, and
# never calls the real launchctl, open, or osascript.
# Usage: zsh -f tests/test_watchdog.zsh

set -u
# Avoid zsh trying to renice the fixture process inside a restricted sandbox.
unsetopt BG_NICE

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
trap '/bin/kill "$sleeper_pid" 2>/dev/null; wait "$sleeper_pid" 2>/dev/null; /bin/rm -rf "$TDIR"' EXIT

if ! /usr/bin/pgrep -u "$UID" -f 'sleep 29631' | grep -qx "$sleeper_pid"; then
  print -u2 'Cannot observe the test process with pgrep; run outside the restricted process sandbox.'
  exit 1
fi

# Only external side effects are substituted; watchdog decisions run unchanged.
export LAUNCHCTL_CALL_LOG="$TDIR/launchctl.calls"
export NOTIFY_CALL_LOG="$TDIR/notify.calls"
fake_launchctl="$TDIR/launchctl"
cat > "$fake_launchctl" <<'STUB'
#!/bin/zsh -f
print -r -- "$*" >> "$LAUNCHCTL_CALL_LOG"
STUB
fake_osascript="$TDIR/osascript"
cat > "$fake_osascript" <<'STUB'
#!/bin/zsh -f
printf '%s\n' "$@" >> "$NOTIFY_CALL_LOG"
cat > /dev/null
STUB
chmod +x "$fake_launchctl" "$fake_osascript"

base_seds=(
  -e "s,^app_path=.*,app_path=\"$TDIR/FakeLuLu.app\","
  -e "s,^log_file=.*,log_file=\"$TDIR/test.log\","
  -e "s,^state_dir=.*,state_dir=\"$TDIR\","
  -e 's,^agent_label=.*,agent_label="com.test.fake-lulu-watchdog",'
  -e 's,^notify_enabled=.*,notify_enabled=0,'
  -e "s,/bin/launchctl,$fake_launchctl,g"
  -e "s,/usr/bin/osascript,$fake_osascript,g"
)
# Detection that never matches any real process
broken_detect=(
  -e 's,-x "LuLu",-x "LuLuZZZZZ",g'
)
# Detection that always matches (the sleeper started above)
match_detect=(
  -e "s,-x \"LuLu\",-P $$ -f \"sleep 29631\",g"
)

mkcopy() {
  local out="$1"; shift
  sed "${base_seds[@]}" "$@" "$SRC" | sed 's,^/usr/bin/open .*,/usr/bin/false,' > "$out"
}

reset_sandbox() {
  # (N) null_glob qualifier: an empty glob must not abort the rm (zsh NOMATCH)
  /bin/rm -f "$TDIR/test.log" "$TDIR"/test.log.*(N) "$TDIR/app-missing-count" \
             "$TDIR/last-seen-running" "$LAUNCHCTL_CALL_LOG" "$NOTIFY_CALL_LOG"
}

log_count() {
  grep -c "$1" "$TDIR/test.log" 2>/dev/null || true
}

run_watchdog() {
  zsh -f "$1" || fail "watchdog exited unsuccessfully: ${1:t}"
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
run_watchdog "$TDIR/t1.zsh"; run_watchdog "$TDIR/t1.zsh"
if [[ ! -e "$LAUNCHCTL_CALL_LOG" ]]; then
  pass "missing app: no bootout before threshold"
else
  fail "missing app: no bootout before threshold"
fi
run_watchdog "$TDIR/t1.zsh"
if [[ "$(cat "$TDIR/app-missing-count" 2>/dev/null)" == "3" ]] \
   && [[ "$(log_count 'missing at')" == "1" ]] \
   && [[ "$(log_count 'disabling watchdog')" == "1" ]]; then
  pass "missing app: counter=3, logged once, disable threshold logged once"
else
  fail "missing app: counter=3, logged once, disable threshold logged once"
fi

if [[ "$(cat "$LAUNCHCTL_CALL_LOG" 2>/dev/null)" == "bootout gui/$UID/com.test.fake-lulu-watchdog" ]]; then
  pass "missing app: bootout current user at threshold"
else
  fail "missing app: bootout current user at threshold"
fi
run_watchdog "$TDIR/t1.zsh"
if [[ -f "$LAUNCHCTL_CALL_LOG" ]] && [[ "$(wc -l < "$LAUNCHCTL_CALL_LOG")" -eq 2 ]] \
   && [[ "$(log_count 'disabling watchdog')" == "1" ]]; then
  pass "missing app: retry bootout without repeating disable log"
else
  fail "missing app: retry bootout without repeating disable log"
fi

# --- Test 2: app back -> counter reset --------------------------------------
reset_sandbox
print "7" > "$TDIR/app-missing-count"
mkcopy "$TDIR/t2.zsh" "${match_detect[@]}"
run_watchdog "$TDIR/t2.zsh"
if [[ ! -f "$TDIR/app-missing-count" ]] && [[ "$(log_count 'present again')" == "1" ]]; then
  pass "app present again: counter removed and reset logged"
else
  fail "app present again: counter removed and reset logged"
fi

# --- Test 2b: exact process match avoids fallback pgrep ---------------------
reset_sandbox
fake_pgrep="$TDIR/fake-pgrep"
print '#!/bin/zsh' > "$fake_pgrep"
print 'print -r -- "$*" >> "$PGREP_CALL_LOG"' >> "$fake_pgrep"
print '[[ " $* " == *" -x LuLu "* ]] && exit 0' >> "$fake_pgrep"
print 'exit 1' >> "$fake_pgrep"
chmod +x "$fake_pgrep"
mkcopy "$TDIR/t2b.zsh" -e "s,/usr/bin/pgrep,$fake_pgrep,g"
PGREP_CALL_LOG="$TDIR/pgrep.calls" run_watchdog "$TDIR/t2b.zsh"
pgrep_call_count=$(wc -l < "$TDIR/pgrep.calls" | tr -d ' ')
if [[ "$pgrep_call_count" == "1" ]] \
   && grep -q -- '-x LuLu' "$TDIR/pgrep.calls" \
   && ! grep -q -- '-f ' "$TDIR/pgrep.calls"; then
  pass "running process: exact pgrep match avoids fallback"
else
  fail "running process: exact pgrep match avoids fallback"
fi

# --- Test 2c: fallback pgrep uses patched app path --------------------------
reset_sandbox
fake_pgrep="$TDIR/fake-pgrep-derived-path"
print '#!/bin/zsh' > "$fake_pgrep"
print 'print -r -- "$*" >> "$PGREP_CALL_LOG"' >> "$fake_pgrep"
print '[[ " $* " == *" -f "* && " $* " == *"$FAKE_LULU_PATTERN"* ]] && exit 0' >> "$fake_pgrep"
print 'exit 1' >> "$fake_pgrep"
chmod +x "$fake_pgrep"
mkcopy "$TDIR/t2c.zsh" -e "s,/usr/bin/pgrep,$fake_pgrep,g"
fake_lulu_pattern="${TDIR//./\\.}/FakeLuLu\\.app/Contents/MacOS/LuLu"
PGREP_CALL_LOG="$TDIR/pgrep-derived.calls" FAKE_LULU_PATTERN="$fake_lulu_pattern" \
  run_watchdog "$TDIR/t2c.zsh"
if grep -Fq -- "$fake_lulu_pattern" "$TDIR/pgrep-derived.calls"; then
  pass "fallback pgrep uses patched app path"
else
  fail "fallback pgrep uses patched app path"
fi

# --- Test 3: open fails -> exit code logged ---------------------------------
reset_sandbox
mkcopy "$TDIR/t3.zsh" "${broken_detect[@]}" -e 's,^/usr/bin/open .*,/usr/bin/false,'
run_watchdog "$TDIR/t3.zsh"
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
run_watchdog "$TDIR/t4.zsh"
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
run_watchdog "$TDIR/t5.zsh"
if grep -Eq 'relaunch confirmed after [0-9]+s \(PID [0-9]+\)' "$TDIR/test.log"; then
  pass "relaunch confirmed with PID"
else
  fail "relaunch confirmed with PID"
fi

# --- Test 5a: relaunch fallback match confirms without exact PID -------------
reset_sandbox
fake_pgrep="$TDIR/fake-pgrep-fallback"
print '#!/bin/zsh' > "$fake_pgrep"
print '[[ " $* " == *" -f "* ]] && exit 0' >> "$fake_pgrep"
print 'exit 1' >> "$fake_pgrep"
chmod +x "$fake_pgrep"
mkcopy "$TDIR/t5a.zsh" -e "s,/usr/bin/pgrep,$fake_pgrep,g" \
                       -e 's,^lulu_running && .*,:,g' \
                       -e 's,^/usr/bin/open .*,/usr/bin/true,' \
                       -e 's,^launch_confirm_timeout=.*,launch_confirm_timeout=1,'
run_watchdog "$TDIR/t5a.zsh"
if grep -q 'relaunch confirmed after 1s (PID unknown)' "$TDIR/test.log"; then
  pass "relaunch fallback match confirms without exact PID"
else
  fail "relaunch fallback match confirms without exact PID"
fi

# --- Test 5b: fresh seen-marker -> notification branch taken ----------------
reset_sandbox
: > "$TDIR/last-seen-running"
mkcopy "$TDIR/t5b.zsh" "${match_detect[@]}" \
                       -e 's,^lulu_running && .*,:,g' \
                       -e 's,^/usr/bin/open .*,/usr/bin/true,' \
                       -e 's,^notify_enabled=.*,notify_enabled=1,'
LULU_WATCHDOG_LANG=en run_watchdog "$TDIR/t5b.zsh"
if [[ "$(cat "$NOTIFY_CALL_LOG" 2>/dev/null)" == "-"$'\n'"LuLu had quit — relaunched (PID $sleeper_pid)"$'\n'"Glass" ]]; then
  pass "fresh marker: English relaunch notification and sound sent once"
else
  fail "fresh marker: English relaunch notification and sound sent once"
fi

# --- Test 5c: date/stat module fallback keeps fresh-marker behavior ----------
reset_sandbox
: > "$TDIR/last-seen-running"
mkcopy "$TDIR/t5c.zsh" "${match_detect[@]}" \
                      -e 's,^lulu_running && .*,:,g' \
                      -e 's,^/usr/bin/open .*,/usr/bin/true,' \
                      -e 's,^notify_enabled=.*,notify_enabled=1,' \
                      -e 's,zmodload -F zsh/datetime b:strftime p:EPOCHSECONDS 2>/dev/null,/usr/bin/false,' \
                      -e 's,zmodload -F zsh/stat b:zstat 2>/dev/null,/usr/bin/false,'
LULU_WATCHDOG_LANG=pl run_watchdog "$TDIR/t5c.zsh"
if [[ "$(cat "$NOTIFY_CALL_LOG" 2>/dev/null)" == "-"$'\n'"LuLu zamknęło się — uruchomiono ponownie (PID $sleeper_pid)"$'\n'"Glass" ]]; then
  pass "date/stat module fallback keeps fresh marker behavior"
else
  fail "date/stat module fallback keeps fresh marker behavior"
fi

# --- Test 5d: stale/no seen-marker -> notification suppressed ---------------
reset_sandbox
LULU_WATCHDOG_LANG=en run_watchdog "$TDIR/t5b.zsh"
if [[ ! -e "$NOTIFY_CALL_LOG" ]] && grep -q 'notification suppressed' "$TDIR/test.log"; then
  pass "no marker: notification suppressed"
else
  fail "no marker: notification suppressed"
fi

# An existing but stale marker must also suppress the external notification.
reset_sandbox
: > "$TDIR/last-seen-running"
touch -t 200001010000 "$TDIR/last-seen-running"
LULU_WATCHDOG_LANG=en run_watchdog "$TDIR/t5b.zsh"
if [[ ! -e "$NOTIFY_CALL_LOG" ]] && grep -q 'notification suppressed' "$TDIR/test.log"; then
  pass "stale marker: notification suppressed"
else
  fail "stale marker: notification suppressed"
fi

reset_sandbox
: > "$TDIR/last-seen-running"
LULU_WATCHDOG_LANG=en run_watchdog "$TDIR/t5.zsh"
if [[ ! -e "$NOTIFY_CALL_LOG" ]] && grep -q 'relaunch confirmed' "$TDIR/test.log"; then
  pass "notifications disabled: fresh relaunch sends nothing"
else
  fail "notifications disabled: fresh relaunch sends nothing"
fi

# --- Test 6: log rotation ----------------------------------------------------
reset_sandbox
print "7" > "$TDIR/app-missing-count"
/usr/bin/head -c 200 /dev/zero | tr '\0' 'x' > "$TDIR/test.log"
mkcopy "$TDIR/t6.zsh" "${match_detect[@]}" -e 's,^max_log_bytes=.*,max_log_bytes=100,'
run_watchdog "$TDIR/t6.zsh"
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
