#!/bin/zsh
#
# Install lulu-watchdog as a per-user LaunchAgent.
# Usage: ./install.sh        (do NOT use sudo)
#
# Messages are shown in English or Polish, auto-detected from the system
# locale. Override with LULU_WATCHDOG_LANG=en or LULU_WATCHDOG_LANG=pl.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
LABEL="com.local.lulu-watchdog"
DEST_DIR="$HOME/Library/Application Support/LuLuWatchdog"
# Installed without the .zsh extension and executed directly by launchd —
# System Settings > Login Items then shows "lulu-watchdog" instead of "zsh"
DEST_SCRIPT="$DEST_DIR/lulu-watchdog"
DEST_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_FILE="$HOME/Library/Logs/LuLuWatchdog.log"

msg_lang="${LULU_WATCHDOG_LANG:-}"
if [[ -z "$msg_lang" ]]; then
    locale_str=$(defaults read -g AppleLocale 2>/dev/null) || locale_str=""
    [[ "$locale_str" == pl* ]] && msg_lang="pl" || msg_lang="en"
fi

# msg "English text" "Polski tekst"
msg() {
    if [[ "$msg_lang" == "pl" ]]; then
        print -r -- "$2"
    else
        print -r -- "$1"
    fi
}

if [[ $EUID -eq 0 ]]; then
    msg "Do not run with sudo — this is a per-user LaunchAgent: ./install.sh" \
        "Nie uruchamiaj przez sudo — to LaunchAgent użytkownika: ./install.sh"
    exit 1
fi

if [[ ! -d /Applications/LuLu.app ]]; then
    msg "WARNING: LuLu.app not found in /Applications. Installing anyway — the watchdog will disable itself after 10 minutes if LuLu stays missing (and re-enable at next login)." \
        "UWAGA: nie znaleziono LuLu.app w /Applications. Instaluję mimo to — watchdog wyłączy się sam po 10 minutach, jeśli LuLu nadal będzie brakować (i włączy się znów przy następnym logowaniu)."
fi

# Stop an existing agent if loaded (try both APIs independently)
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl unload "$DEST_PLIST" 2>/dev/null || true

mkdir -p "$DEST_DIR" "$(dirname "$DEST_PLIST")"

# Clean up the legacy install name (script used to be installed as *.zsh)
rm -f "$DEST_DIR/lulu-watchdog.zsh"

cp "$SCRIPT_DIR/lulu-watchdog.zsh" "$DEST_SCRIPT"
chmod 700 "$DEST_SCRIPT"

sed "s|__HOME__|$HOME|g" "$SCRIPT_DIR/com.local.lulu-watchdog.plist" > "$DEST_PLIST"
chmod 644 "$DEST_PLIST"

# Start agent (try modern API first, fall back to legacy)
bootstrap_err=""
load_err=""
if ! bootstrap_err=$(launchctl bootstrap "gui/$UID" "$DEST_PLIST" 2>&1); then
    if ! load_err=$(launchctl load "$DEST_PLIST" 2>&1); then
        msg "WARNING: launchctl bootstrap failed: $bootstrap_err" \
            "UWAGA: launchctl bootstrap nie powiódł się: $bootstrap_err"
        msg "WARNING: launchctl load failed: $load_err" \
            "UWAGA: launchctl load nie powiódł się: $load_err"
    fi
fi

# Verify — RunAtLoad fires the first check immediately; expect a clean exit
sleep 2
last_exit=$( (launchctl print "gui/$UID/$LABEL" 2>/dev/null || true) | awk '/last exit code/ { print $NF }')
if [[ "$last_exit" == "0" || "$last_exit" == "(never" ]]; then
    msg "Installed and running (checks LuLu every 30 s)." \
        "Zainstalowano i działa (sprawdza LuLu co 30 s)."
    msg "  Script: $DEST_SCRIPT" "  Skrypt: $DEST_SCRIPT"
    msg "  Plist:  $DEST_PLIST" "  Plist:  $DEST_PLIST"
    msg "  Log:    $LOG_FILE" "  Log:    $LOG_FILE"
    print ""
    msg "Commands:" "Polecenia:"
    msg "  tail -f \"$LOG_FILE\"    # watch log" \
        "  tail -f \"$LOG_FILE\"    # podgląd logu"
    msg "  ./uninstall.sh    # remove" \
        "  ./uninstall.sh    # odinstaluj"
    print ""
    msg "To intentionally quit LuLu, stop the watchdog first:" \
        "Aby celowo wyłączyć LuLu, najpierw zatrzymaj watchdoga:"
    print -r -- "  launchctl bootout gui/$UID/$LABEL"
else
    msg "WARNING: Agent failed to start (last exit code: ${last_exit:-unknown})." \
        "UWAGA: agent nie wystartował (ostatni kod wyjścia: ${last_exit:-nieznany})."
    msg "  Debug: launchctl print gui/$UID/$LABEL" \
        "  Diagnostyka: launchctl print gui/$UID/$LABEL"
    exit 1
fi
