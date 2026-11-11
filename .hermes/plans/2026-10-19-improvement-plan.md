---
# update-my-mac-improvements
title: Verbesserungsplan für update-my-mac.sh
status: proposed
type: feature
priority: normal
created_at: 2026-10-19
---

## Kontext

Dieser Plan hält die Erkenntnisse aus der Analyse vom 2026-10-19 fest. Der User war zu diesem Zeitpunkt anderweitig beschäftigt; die Erkenntnisse sollen nicht verloren gehen und später umgesetzt werden.

## Zielsetzung

1. **Durchlaufen statt hängenbleiben:** Das Skript soll auch bei Fehlern komplett durchlaufen. Fehler müssen zuverlässig im Log landen, damit die LLM-Analyse sie interpretieren kann.
2. **Kein sudo mehr nötig:** Das Skript soll als normaler User im Hintergrund laufen, ohne interaktive Passwortprompts.
3. **System-Update-Bug beheben/entfernen:** `softwareupdate`-Logik funktioniert zuverlässig nicht und soll geprüft bzw. entfernt werden.

## Befund: Berechtigungsproblem (sudo-Ursache)

**Diagnose (ausgeführt am 2026-10-19):**
- Brew-Prefix ist **sauber**: `/opt/homebrew`, `bin`, `Cellar`, `var` gehören `GEO5BE4`.
- **Das Problem liegt bei globalen Node-Paketen:** ~294.651 Dateien unter `/opt/homebrew/lib/node_modules` (+ Symlinks in `/opt/homebrew/bin`) gehören `root`.
- Das erklärt den sudo-Prompt bei `npm`/`bun`/`pnpm` globalen Updates: npm will in ein root-eigenes Verzeichnis schreiben.
- **Fix bereits ausgeführt:** `sudo chown -R $(whoami):admin /opt/homebrew/lib/node_modules /opt/homebrew/bin`
- **Wichtig:** `brew doctor` erkennt dieses Problem (root-Dateien in `lib/node_modules`) *nicht* — es ist nicht Brews eigener Bereich. Ein gezielter `find "$(brew --prefix)/lib/node_modules" -user root` ist nötig.

## Geplante Änderungen

### 1. Fehlerbehandlung vereinheitlichen („alles landet im Log")
- `print_error`/`print_warning` sollen als **zentraler Gatekeeper** fungieren und *immer* eine klar markierte, strukturierte Log-Zeile schreiben.
- Fix-Instruktionen explizit anhängen, z.B. `[ERROR] [fix: brew install mas] mas-cli not installed`.
- LLM-Analyse (`ANALYSIS_PROMPT`) schärfen: explizit nach ERROR-Zeilen suchen lassen.
- Ziel: Ein Agent, der das Tool nutzt, kann Fehler aus dem Log verstehen und deren Fix-Kommandos ableiten.

### 2. System-Update-Logik entfernen
- `update_system()` und der Xcode-`softwareupdate`-Teil sind unzuverlässig (System-Updates laufen über die Systemeinstellungen bzw. brauchen Neustart).
- Aus `update_all()` und `show_help()` entfernen.

### 3. `brew doctor`-Ausgabe ins Log
- `brew doctor` nach dem Update ausführen, Ausgabe ins Log schreiben (für die LLM-Analyse).
- Zusätzlich: gezielter root-Dateien-Check in `/opt/homebrew/lib/node_modules` (da `brew doctor` das nicht abdeckt).

### 4. `--dry-run` ergänzen
- Zeigt an, *was* aktualisiert würde, ohne auszuführen.
- Ideal zum Testen und Verifizieren.

### 5. Optionale/spätere Ideen (nicht priorisiert)
- **Parallelität:** Entscheidung zurückgestellt — User lässt Updates im Hintergrund laufen und schätzt vombares Log. Falls je gewünscht: Pro-Tool-Logs (`update-<timestamp>-brew.log`, usw.) + deterministische Konkatenation für die LLM-Analyse.
- **`mise`/`asdf`**, **`cargo install-update`**, **`pipx upgrade-all`** als zusätzliche Toolchain-Updater.
- **`show_help()`**: sagt `update.sh` statt `update-my-mac.sh` (Kleinkram).
- Logging vor `--help`/`--version` vermeiden (vermeidet leere Log-Dateien).

## Offene Frage (beim Umsetzen)

- Soll nur `update_system` entfernt werden, oder auch der Xcode-`softwareupdate`-Teil? (Empfehlung: beide, da beide `softwareupdate` nutzen und unzuverlässig sind.)
- Soll die LLM-Analyse am Ende in jedem Fall erhalten bleiben? (Empfehlung: ja — Kernfeature des Skripts.)
