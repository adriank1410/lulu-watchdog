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
# macOS notifications (localized EN/PL, see notify()); set to 0 to disable
notify_enabled=1
# Notify only when LuLu was seen running within this many seconds. This both
# limits notifications to one per outage episode (later ticks of the same
# outage see a stale marker) and silences the login race where the agent's
# first tick fires before LuLu's own login item has started the app. Must be
# longer than one StartInterval tick and shorter than two.
notify_fresh_seconds=45
seen_marker_file="${state_dir}/last-seen-running"

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

recently_seen_running() {
  local marker_mtime now_epoch
  marker_mtime=$(/usr/bin/stat -f "%m" "$seen_marker_file" 2>/dev/null) || return 1
  now_epoch=$(/bin/date +%s)
  (( now_epoch - marker_mtime <= notify_fresh_seconds ))
}

# notify "English text" "Polski tekst" "SoundName" — language auto-detected
# from the system locale, override with LULU_WATCHDOG_LANG=en|pl (set it via
# EnvironmentVariables in the plist to affect the agent). The text reaches
# AppleScript through argv, never string interpolation.
notify() {
  (( notify_enabled )) || return 0
  local msg_lang msg_text
  msg_lang="${LULU_WATCHDOG_LANG:-}"
  if [[ -z "$msg_lang" ]]; then
    [[ "$(defaults read -g AppleLocale 2>/dev/null)" == pl* ]] && msg_lang="pl" || msg_lang="en"
  fi
  [[ "$msg_lang" == "pl" ]] && msg_text="$2" || msg_text="$1"
  /usr/bin/osascript - "$msg_text" "$3" >/dev/null 2>&1 <<'OSA' || true
on run argv
    display notification (item 1 of argv) with title "LuLu Watchdog" sound name (item 2 of argv)
end run
OSA
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
    notify "LuLu app is still missing — watchdog disabled until next login" \
           "Aplikacji LuLu wciąż brak — watchdog wyłączony do następnego logowania" "Basso"
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

lulu_running && { : > "$seen_marker_file"; exit 0 }

# Decide once per tick whether this outage is fresh (LuLu seen running
# within notify_fresh_seconds) — only fresh outages produce notifications
if recently_seen_running; then
  episode_fresh=1
else
  episode_fresh=0
fi

log_message "LuLu process missing; launching app"
/usr/bin/open -gj -a "$app_path"
open_rc=$?
if (( open_rc != 0 )); then
  log_message "open failed (exit ${open_rc}); will retry on next tick"
  if (( episode_fresh )); then
    notify "LuLu quit and the relaunch failed (open exit ${open_rc})" \
           "LuLu zamknęło się, a ponowne uruchomienie nie powiodło się (open: kod ${open_rc})" "Basso"
  fi
  exit 0
fi

waited=0
while (( waited < launch_confirm_timeout )); do
  /bin/sleep 1
  waited=$(( waited + 1 ))
  if lulu_running; then
    lulu_pids=($(/usr/bin/pgrep -u "$UID" -x "LuLu" 2>/dev/null))
    log_message "relaunch confirmed after ${waited}s (PID ${lulu_pids[1]:-unknown})"
    if (( episode_fresh )); then
      notify "LuLu had quit — relaunched (PID ${lulu_pids[1]:-?})" \
             "LuLu zamknęło się — uruchomiono ponownie (PID ${lulu_pids[1]:-?})" "Glass"
    else
      log_message "notification suppressed (LuLu not recently seen running — login/install race or ongoing outage)"
    fi
    : > "$seen_marker_file"
    exit 0
  fi
done
log_message "relaunch NOT confirmed within ${launch_confirm_timeout}s; will retry on next tick"
if (( episode_fresh )); then
  notify "LuLu quit and the relaunch was not confirmed — check it manually" \
         "LuLu zamknęło się, a ponowne uruchomienie nie zostało potwierdzone — sprawdź ręcznie" "Basso"
fi
