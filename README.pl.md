# lulu-watchdog

🇬🇧 [English version](README.md)

Pilnuje, żeby aplikacja GUI zapory [LuLu](https://objective-see.org/products/lulu.html) (Objective-See) była zawsze uruchomiona — dzięki temu alerty o nowych połączeniach nigdy nie znikają po cichu.

## Problem

Rozszerzenie sieciowe LuLu egzekwuje **istniejące** reguły nawet wtedy, gdy aplikacja GUI jest zamknięta — rozszerzenie działa niezależnie. Jednak alerty o **nowych** połączeniach wyświetla właśnie aplikacja GUI. Gdy ta cicho się zamknie (zdarza się sporadycznie), nie masz możliwości zezwolenia ani zablokowania nowych połączeń. Ten watchdog leczy ten objaw.

## Co robi

1. **Sprawdza co 30 sekund** — LaunchAgent uruchamia jedno wywołanie zsh i jeden `pgrep`, zużywając kilka milisekund CPU i zero pamięci rezydentnej między tickami.
2. **Restartuje LuLu ukrytego w tle** — używa `open -gj -a LuLu.app`, dzięki czemu aplikacja pojawia się bez przejmowania fokusu.
3. **Potwierdza restart w ciągu 10 sekund** — odpytuje, aż proces będzie widoczny, po czym loguje jego PID.
4. **Loguje błędy `open` wraz z kodem wyjścia** — kolejny tick za 30 sekund jest automatyczną próbą ponowną.
5. **Wyłącza się automatycznie po 10 minutach ciągłej nieobecności LuLu** — dopiero 20 kolejnych ticków „brak aplikacji" wyzwala `launchctl bootout`, więc aktualizacja LuLu (która może chwilowo podmienić bundle `.app`) nie wyłączy watchdoga.
6. **Włącza się ponownie przy następnym logowaniu** — `RunAtLoad: true` w pliście uruchamia agenta po każdym logowaniu.
7. **Rotuje log przy 256 KB**, zachowując 3 zrotowane pliki.
8. **Solidne wykrywanie procesu** — zakotwiony wzorzec `pgrep -f` tolerujący argumenty CLI, plus fallback `pgrep -x` dla ścieżek po app-translocation, oba ograniczone do bieżącego użytkownika (`-u $UID`), żeby proces LuLu innego użytkownika przy fast user switching nie maskował braku aplikacji.

## Uwagi projektowe

**Dlaczego nie wskazać launchd `KeepAlive` bezpośrednio na binarny plik LuLu?**  
LuLu rejestruje własny element logowania. Drugi agent `KeepAlive` walczyłby z tym elementem i ryzykowałby uruchomienie drugiej instancji, ingerując w własne zarządzanie cyklem życia LuLu.

**Dlaczego odpytywanie co 30 sekund zamiast rezydentnego obserwatora zdarzeń `NSWorkspace`?**  
Odpytywanie nie zużywa pamięci rezydentnej między tickami. Fałszywe „nie działa" jest nieszkodliwe: `open -a` na działającej już aplikacji nie uruchamia drugiej instancji — operacja jest idempotentna.

## Instalacja

Nie wymaga `sudo` — to LaunchAgent użytkownika.

```bash
git clone https://github.com/adriank1410/lulu-watchdog.git
cd lulu-watchdog
./install.sh
```

Instalator i deinstalator automatycznie wykrywają język (angielski lub polski) na podstawie lokalizacji systemowej (`AppleLocale`). Możesz to nadpisać:

```bash
LULU_WATCHDOG_LANG=en ./install.sh   # wymuś angielski
LULU_WATCHDOG_LANG=pl ./install.sh   # wymuś polski
```

## Deinstalacja

```bash
./uninstall.sh
```

Pliki logów pozostają w `~/Library/Logs/LuLuWatchdog.log*` po deinstalacji.

## Użytkowanie

```bash
# Podgląd logu na żywo
tail -f ~/Library/Logs/LuLuWatchdog.log

# Sprawdzenie statusu agenta
launchctl print gui/$UID/com.local.lulu-watchdog

# Zastosowanie zmian w skrypcie watchdoga
./install.sh
```

> **Ważne:** Aby celowo zamknąć LuLu, najpierw zatrzymaj watchdoga — inaczej wskrzesi LuLu w ciągu 30 sekund:
> ```bash
> launchctl bootout gui/$UID/com.local.lulu-watchdog
> ```

## Konfiguracja

Edytuj stałe na początku pliku `lulu-watchdog.zsh`, a następnie uruchom ponownie `./install.sh`, żeby zastosować zmiany.

| Stała | Wartość domyślna | Opis |
|---|---|---|
| `app_path` | `/Applications/LuLu.app` | Ścieżka do bundle aplikacji LuLu |
| `lulu_executable` | `$app_path/Contents/MacOS/LuLu` | Oczekiwany plik wykonywalny w bundle |
| `log_file` | `~/Library/Logs/LuLuWatchdog.log` | Ścieżka do pliku logu |
| `state_dir` | `~/Library/Application Support/LuLuWatchdog` | Katalog stanu (licznik braków) |
| `agent_label` | `com.local.lulu-watchdog` | Etykieta LaunchAgent |
| `max_log_bytes` | `262144` (256 KB) | Rozmiar logu wyzwalający rotację |
| `max_rotated_logs` | `3` | Liczba zachowywanych zrotowanych plików logu |
| `max_app_missing_checks` | `20` | Kolejne ticki „brak" przed samo-wyłączeniem (20 × 30 s = 10 min) |
| `launch_confirm_timeout` | `10` | Sekundy oczekiwania na potwierdzenie restartu |
| `StartInterval` | `30` | Sekundy między tickami (ustawione w pliście, nie w skrypcie) |

## Pliki

| Plik w repozytorium | Zainstalowany w |
|---|---|
| `lulu-watchdog.zsh` | `~/Library/Application Support/LuLuWatchdog/lulu-watchdog` |
| `com.local.lulu-watchdog.plist` | `~/Library/LaunchAgents/com.local.lulu-watchdog.plist` |
| *(generowany w trakcie działania)* | `~/Library/Logs/LuLuWatchdog.log` |

Skrypt jest instalowany bez rozszerzenia `.zsh` i wykonywany przez launchd bezpośrednio (a nie jako `zsh skrypt.zsh`) — dzięki temu **Ustawienia systemowe → Ogólne → Elementy logowania** pokazują agenta jako `lulu-watchdog`, a nie anonimowe `zsh`.

## Testy

Zestaw testów uruchamia w piaskownicy kopie skryptu z podstawionymi ścieżkami. Nie wymaga ani zainstalowanego, ani działającego LuLu i nigdy nie dotyka prawdziwego LaunchAgenta.

```bash
zsh tests/test_watchdog.zsh
```

## Wymagania

- macOS z zainstalowanym [LuLu](https://objective-see.org/products/lulu.html) w `/Applications`

## Licencja

[MIT](LICENSE)
