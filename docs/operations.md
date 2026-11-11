# Operating the update script

## Cadence

| When | Command | What it does |
|---|---|---|
| Daily, cheap | `./update-my-mac.sh --report` | prints eligible vs held with ages; changes nothing, waits for nothing |
| Weekly, interactive | `./update-my-mac.sh --quick` | gated brew + npm/bun/uv + plugin state |
| Occasionally | `./update-my-mac.sh --full` | adds App Store, Xcode, system updates |
| After a policy change | `./update-my-mac.sh --cooldown-sync` | re-derives every per-tool config from `cooldown.env` |

`--quick` is the default when no flag is given.

Casks with `pkg`/`installer`/`kext` stanzas need sudo and therefore need a real
terminal. In a cron or agent run they will always appear as pending.

## Where things live

| Path | Contents |
|---|---|
| `~/.config/cooldown/cooldown.env` | the two windows (`COOLDOWN_HOURS`, `COOLDOWN_HOURS_CORE`) |
| `~/Library/Logs/update-my-mac/update-*.log` | one log per run, full command output |
| `~/Library/Logs/update-my-mac/brew-cooldown-*.json` | the gate's decision for every pending package |
| `~/Library/Logs/update-my-mac/brew-eligible-*.txt` | the exact target list passed to `brew upgrade` |
| `~/.cache/update-my-mac/brew-age.json` | cached merge dates, 24 h TTL |
| `<repo>/lib/cooldown.py` | the gate itself |

The log is analysed by `llm` at the end of a run when that tool is installed; without it
the step is skipped.

## Reading a hold

```
Cooldown 72h (homebrew-core 24h) - Homebrew plan
  held     : 24
  gh        formula  2.103.1   2.1h old, 21.9h to go     ← 24h window (core)
  calibre   cask     9.17.0   13.0h old,  2.5d to go     ← 72h window (cask)
  hatch     formula  1.18.1_2  1.3h old,  pulls dependency certifi, which is inside the window
```

`to go` counts against the package's own window. The third line is a package that would
otherwise be eligible but whose dependency is still young.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Cooldown gate could not evaluate Homebrew state` | `brew outdated` or `brew info` failed twice (usually a held lock) | rerun; if it persists, run `brew outdated --json=v2` by hand and read the error |
| everything `unknown`, held | `gh` not authenticated or offline, and no local tap clone | `gh auth status`, then `gh auth login` |
| `gh: Not Found (HTTP 404)` for one package | definition path moved, or a very fresh tap commit | package is held; update `brew` (`brew update`) and retry |
| cask fails with `sudo: a terminal is required` | cask installs with root | run in a real terminal |
| cask fails with `It seems there is already an App at …` after an interrupted run | leftover `.upgrading` directory | `rm -rf /opt/homebrew/Caskroom/<cask>/<version>.upgrading`, then retry |
| `npm` branch says "ignores min-release-age" | an npm older than 11.10 is first in `PATH` | put `/opt/homebrew/bin` before bundled node installs |
| pnpm fails with `Permission denied … store/v11/files` | the store directory is owned by another user (e.g. after a `sudo pnpm install`) | `sudo rm -rf ~/Library/pnpm/store/v11`, pnpm recreates it |
| `--report` shows 0 eligible for days | that is the policy working, not a bug | check the `to go` column |

## Emergency: taking something now

```bash
# one package, brew gate only, recorded in the plan JSON
./update-my-mac.sh --bypass gh --brew

# a whole run without the gate (brew, uv and npm only - pnpm/bun/deno keep their config)
./update-my-mac.sh --no-cooldown --brew
```

Both are one-shot. Nothing is written to any config, so the next normal run enforces the
window again. To make an exception permanent, add it to the manager's own exclude list
(`docs/cooldown.md`) with a date and a reason.

## Verifying the setup

```bash
./update-my-mac.sh --cooldown-status     # want vs have per manager, flags INEFFECTIVE settings
python3 lib/cooldown.py selftest         # offline checks of the classification rules
zsh -n update-my-mac.sh                  # syntax check
```

`--cooldown-status` is the one to run after any tool upgrade: it is the only place that
tells you a setting is present but not honoured (`IGNORED`, `PRE-STAGED`).

## Installation layout

The script is not a single file — the gate lives in `lib/cooldown.py` and must sit next to
it:

```
/usr/local/libexec/update-my-mac/update-my-mac.sh
/usr/local/libexec/update-my-mac/lib/cooldown.py
/usr/local/bin/update-my-mac -> ../libexec/update-my-mac/update-my-mac.sh
```

After pulling a new version, re-run `./update-my-mac.sh --install`; `--version` reports
which layout is currently installed and whether the helper was found. An older flat-file
install shows up as `(flat file - old layout, missing lib/)` and refuses every brew
upgrade.

`UPDATE_MY_MAC_PREFIX` (default `/usr/local`) and `UPDATE_MY_MAC_HELPER` override the
install prefix and helper path.
