# lulu-watchdog

Keeps the GUI app of the [LuLu](https://objective-see.org/products/lulu.html) firewall (by Objective-See) alive so new-connection alerts are never silently missed.

## Problem

LuLu's network extension keeps enforcing **existing** rules even when the GUI app is closed — the extension itself runs independently. However, alerts for **new** connections are displayed by the GUI app. When the GUI silently quits (which happens occasionally), you never get the chance to allow or deny new connections. This watchdog treats that symptom.

## What it does

1. **Checks every 30 seconds** — a LaunchAgent fires one zsh invocation and one `pgrep`, taking a few milliseconds of CPU and zero resident memory between ticks.
2. **Relaunches LuLu hidden in the background** — uses `open -gj -a LuLu.app` so the app appears without stealing focus.
3. **Confirms the relaunch within 10 seconds** — polls until the process is visible, then logs the PID.
4. **Logs open failures with their exit code** — the next 30-second tick is the automatic retry.
5. **Self-disables after 10 minutes of continuous LuLu absence** — it takes 20 consecutive "missing" ticks to trigger `launchctl bootout`, so a LuLu update (which can briefly replace the `.app` bundle) does not disable the watchdog.
6. **Auto-re-enables at next login** — `RunAtLoad: true` in the plist restarts the agent after each login.
7. **Rotates its log at 256 KB**, keeping 3 rotated files.
8. **Robust process detection** — an anchored `pgrep -f` pattern that tolerates CLI arguments, plus a `pgrep -x` fallback for app-translocation paths, both scoped to the current user (`-u $UID`) so another user's LuLu process under fast user switching does not mask the absence.

## Design notes

**Why not point launchd `KeepAlive` directly at LuLu's binary?**  
LuLu registers its own login item. Having a second `KeepAlive` agent fight that item risks spawning a second instance and interfering with LuLu's own lifecycle management.

**Why 30-second polling instead of a resident `NSWorkspace` notification observer?**  
Polling costs zero resident memory between ticks. A false "not running" verdict is harmless: `open -a` on an already-running app does not launch a second instance — it is idempotent.

## Install

No `sudo` required — this is a per-user LaunchAgent.

```bash
git clone https://github.com/adriank1410/lulu-watchdog.git
cd lulu-watchdog
./install.sh
```

The installer and uninstaller auto-detect English or Polish from the system locale (`AppleLocale`). Override with:

```bash
LULU_WATCHDOG_LANG=en ./install.sh   # force English
LULU_WATCHDOG_LANG=pl ./install.sh   # force Polish
```

## Uninstall

```bash
./uninstall.sh
```

Log files remain in `~/Library/Logs/LuLuWatchdog.log*` after uninstall.

## Usage

```bash
# Watch the live log
tail -f ~/Library/Logs/LuLuWatchdog.log

# Check agent status
launchctl print gui/$UID/com.local.lulu-watchdog

# Apply edits to the watchdog script
./install.sh
```

> **Important:** To intentionally quit LuLu, stop the watchdog first — otherwise it resurrects LuLu within 30 seconds:
> ```bash
> launchctl bootout gui/$UID/com.local.lulu-watchdog
> ```

## Configuration

Edit the constants at the top of `lulu-watchdog.zsh`, then re-run `./install.sh` to apply.

| Constant | Default | Description |
|---|---|---|
| `app_path` | `/Applications/LuLu.app` | Path to the LuLu application bundle |
| `lulu_executable` | `$app_path/Contents/MacOS/LuLu` | Expected executable inside the bundle |
| `log_file` | `~/Library/Logs/LuLuWatchdog.log` | Log file path |
| `state_dir` | `~/Library/Application Support/LuLuWatchdog` | State directory (miss counter) |
| `agent_label` | `com.local.lulu-watchdog` | LaunchAgent label |
| `max_log_bytes` | `262144` (256 KB) | Log size that triggers rotation |
| `max_rotated_logs` | `3` | Number of rotated log files to keep |
| `max_app_missing_checks` | `20` | Consecutive "missing" ticks before self-disable (20 × 30 s = 10 min) |
| `launch_confirm_timeout` | `10` | Seconds to wait for relaunch confirmation |
| `StartInterval` | `30` | Seconds between ticks (set in the plist, not the script) |

## Files

| Repo file | Installed to |
|---|---|
| `lulu-watchdog.zsh` | `~/Library/Application Support/LuLuWatchdog/lulu-watchdog` |
| `com.local.lulu-watchdog.plist` | `~/Library/LaunchAgents/com.local.lulu-watchdog.plist` |
| *(generated at runtime)* | `~/Library/Logs/LuLuWatchdog.log` |

The script is installed without the `.zsh` extension and executed directly by launchd (not as `zsh script.zsh`) — this way **System Settings → General → Login Items** lists the agent as `lulu-watchdog` instead of an anonymous `zsh`.

## Tests

The test suite runs sandboxed copies of the script with substituted paths. It requires neither LuLu installed nor running, and never touches the real LaunchAgent.

```bash
zsh tests/test_watchdog.zsh
```

## Requirements

- macOS with [LuLu](https://objective-see.org/products/lulu.html) installed in `/Applications`

## License

[MIT](LICENSE)
