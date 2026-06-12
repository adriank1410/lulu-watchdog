#!/bin/zsh
#
# Uninstall lulu-watchdog.
# Usage: ./uninstall.sh        (do NOT use sudo)

set -euo pipefail

LABEL="com.local.lulu-watchdog"
DEST_DIR="$HOME/Library/Application Support/LuLuWatchdog"
DEST_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

msg_lang="${LULU_WATCHDOG_LANG:-}"
if [[ -z "$msg_lang" ]]; then
    locale_str=$(defaults read -g AppleLocale 2>/dev/null) || locale_str=""
    [[ "$locale_str" == pl* ]] && msg_lang="pl" || msg_lang="en"
fi

msg() {
    if [[ "$msg_lang" == "pl" ]]; then
        print -r -- "$2"
    else
        print -r -- "$1"
    fi
}

if [[ $EUID -eq 0 ]]; then
    msg "Do not run with sudo — this is a per-user LaunchAgent: ./uninstall.sh" \
        "Nie uruchamiaj przez sudo — to LaunchAgent użytkownika: ./uninstall.sh"
    exit 1
fi

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null \
    || launchctl unload "$DEST_PLIST" 2>/dev/null \
    || true
rm -f "$DEST_PLIST"
rm -rf "$DEST_DIR"

msg "Uninstalled. Log files remain in ~/Library/Logs/LuLuWatchdog.log*" \
    "Odinstalowano. Pliki logów zostają w ~/Library/Logs/LuLuWatchdog.log*"
