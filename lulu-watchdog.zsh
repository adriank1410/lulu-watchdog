#!/bin/zsh
#
# lulu-watchdog — relaunches the LuLu firewall GUI app when it is not running.
#
# LuLu's network extension keeps enforcing existing rules even when the GUI
# app is closed, but without the GUI no alert is shown for NEW connections,
# so you never get to allow/deny them. This watchdog runs every 30 s from a
# LaunchAgent and relaunches the app (hidden, in the background) if missing.

set -u
umask 077

app_path="/Applications/LuLu.app"
lulu_executable="${app_path}/Contents/MacOS/LuLu"
log_file="${HOME}/Library/Logs/LuLuWatchdog.log"
state_dir="${HOME}/Library/Application Support/LuLuWatchdog"
miss_count_file="${state_dir}/app-missing-count"
agent_label="com.local.lulu-watchdog"
max_log_bytes=262144
max_rotated_logs=3
# 20 ticks x 30 s = 10 min of continuous app absence before the agent
# disables itself -- the hysteresis prevents self-disabling while the .app
# bundle is briefly replaced during a LuLu update
max_app_missing_checks=20
launch_confirm_timeout=10

timestamp() {
  /bin/date "+%Y-%m-%d %H:%M:%S"
}

rotate_log_if_needed() {
  [[ -f "$log_file" ]] || return 0

  local log_size
  log_size=$(/usr/bin/stat -f "%z" "$log_file" 2>/dev/null) || return 0
  (( log_size < max_log_bytes )) && return 0

  local index next_index rotated_file next_file
  index="$max_rotated_logs"
  while (( index >= 1 )); do
    rotated_file="${log_file}.${index}"
    if (( index == max_rotated_logs )); then
      [[ -e "$rotated_file" ]] && /bin/rm -f "$rotated_file"
    else
      next_index=$(( index + 1 ))
      next_file="${log_file}.${next_index}"
      [[ -e "$rotated_file" ]] && /bin/mv -f "$rotated_file" "$next_file"
    fi
    index=$(( index - 1 ))
  done

  /bin/mv -f "$log_file" "${log_file}.1"
  : > "$log_file"
  /bin/chmod 600 "$log_file" "${log_file}.1" 2>/dev/null || true
}

log_message() {
  [[ -d "${log_file:h}" ]] || /bin/mkdir -p "${log_file:h}"
  rotate_log_if_needed
  print -r -- "$(timestamp) $1" >> "$log_file"
}

# "( |$)" anchor instead of "$": survives LuLu being started with a CLI
# argument. Fallback pgrep -x: survives a start from an unusual path (e.g.
# app translocation). -u $UID: another user's LuLu (fast user switching)
# does not count as running in this session. A false "not running" is cheap:
# open -a on an already-running app does not spawn a second instance.
lulu_running() {
  /usr/bin/pgrep -u "$UID" -f '^/Applications/LuLu\.app/Contents/MacOS/LuLu( |$)' >/dev/null 2>&1 && return 0
  /usr/bin/pgrep -u "$UID" -x "LuLu" >/dev/null 2>&1
}

if [[ ! -d "$app_path" || ! -x "$lulu_executable" ]]; then
  miss_count=0
  [[ -f "$miss_count_file" ]] && miss_count=$(<"$miss_count_file")
  [[ "$miss_count" == <-> ]] || miss_count=0
  miss_count=$(( miss_count + 1 ))
  print -r -- "$miss_count" > "$miss_count_file"

  if (( miss_count == 1 )); then
    log_message "LuLu app or executable missing at $app_path; will disable watchdog after ${max_app_missing_checks} consecutive checks"
  fi
  if (( miss_count == max_app_missing_checks )); then
    log_message "LuLu still missing after ${miss_count} checks; disabling watchdog until next login (re-enable now: launchctl bootstrap gui/$UID ~/Library/LaunchAgents/${agent_label}.plist)"
  fi
  if (( miss_count >= max_app_missing_checks )); then
    # bootout kills this process (SIGTERM) -- must be the last action
    /bin/launchctl bootout "gui/$UID/${agent_label}" 2>/dev/null
  fi
  exit 0
fi

if [[ -f "$miss_count_file" ]]; then
  /bin/rm -f "$miss_count_file"
  log_message "LuLu app present again; miss counter reset"
fi

lulu_running && exit 0

log_message "LuLu process missing; launching app"
/usr/bin/open -gj -a "$app_path"
open_rc=$?
if (( open_rc != 0 )); then
  log_message "open failed (exit ${open_rc}); will retry on next tick"
  exit 0
fi

waited=0
while (( waited < launch_confirm_timeout )); do
  /bin/sleep 1
  waited=$(( waited + 1 ))
  if lulu_running; then
    lulu_pids=($(/usr/bin/pgrep -u "$UID" -x "LuLu" 2>/dev/null))
    log_message "relaunch confirmed after ${waited}s (PID ${lulu_pids[1]:-unknown})"
    exit 0
  fi
done
log_message "relaunch NOT confirmed within ${launch_confirm_timeout}s; will retry on next tick"
