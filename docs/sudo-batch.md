# Sudo-deferred upgrades and the batch mode

Some Homebrew casks need root to upgrade: `pkg` installers, kernel extensions,
system daemons. Homebrew invokes `sudo` for more than just installers — every
cask with an `uninstall launchctl`, `delete`, `pkgutil`, `kext` or `script`
stanza triggers a sudo call, even when the service is user-level (brew probes
`launchctl print system/<label>` via sudo). On top of that, brew resets sudo's
credential cache once per process, so a long upgrade can ask for the password
several times in a row.

This script splits the problem in two:

1. **Unattended runs never prompt.** Root-requiring upgrades are classified
   `sudo` by the gate, skipped, and listed in the report.
2. **`--sudo-batch` installs them together**, with one password prompt.

## Normal runs

`--quick`, `--brew`, cron, agent runs: the gate marks every age-eligible cask
that needs root as `sudo` (deferred) instead of `eligible`. The report shows
them in their own bucket:

```
  sudo     : 6  (deferred - needs root, run: update-my-mac --sudo-batch)

Deferred, needs sudo (6) - install together with: update-my-mac --sudo-batch
  deepl                 cask     1.14.0    uninstall launchctl
  naps2                 cask     8.2.1     pkg installer, uninstall pkgutil
  …
```

Everything else upgrades as usual. As a safety net, the upgrade command runs
with `SUDO_ASKPASS=lib/sudo-askpass-defer.sh`: if a sudo attempt slips past the
classifier, brew's `sudo -A` calls that stub, it exits 1, and sudo fails
immediately instead of prompting. The stub contains no secrets and reads
nothing; the failure is reported with a pointer to `--sudo-batch`.

## The batch

```bash
update-my-mac --sudo-batch            # interactive terminal required
update-my-mac --dry-run --sudo-batch  # show the targets, change nothing
```

What happens:

1. `brew update` and a **fresh gate plan** — the batch is re-derived from
   current state, never from a stale list. The cooldown stays enforced: only
   deferred names that are past their age window are installed.
2. `sudo -v` — **the one password prompt**, handled by sudo itself on the
   terminal. The script never sees, stores, logs or forwards the password.
3. A keep-alive runs `sudo -n true` every 50 s so long downloads do not expire
   the ticket (sudo's default timeout is 5 minutes). Only the non-interactive
   check runs — never a password.
4. `HOMEBREW_SUDO_CHECKED=1` tells brew to skip its timestamp-reset probe, so
   the ticket from step 2 survives into the upgrade.
5. One `brew upgrade <name> …` invocation for the whole batch.
6. On every exit path (success, error, Ctrl-C): keep-alive killed, `sudo -k`
   invalidates the ticket. The root window closes with the batch.

If your sudoers sets `timestamp_timeout=0`, caching is disabled and the batch
warns that repeated prompts are unavoidable — that is a policy choice, not a
script limitation.

## Security properties

- No `sudo -S`, no password in argv, environment, files or logs. The only
  credential cache is sudo's own timestamp store (root-owned).
- The askpass stub is an exit-1 no-op; it cannot leak anything.
- The batch is tty-only and refuses to run from cron/agents.
- The batch never bypasses the cooldown: same gate, same windows, explicit
  names only. `--bypass` overrides the age window but not the sudo deferral —
  bypassed root-requiring casks join the batch too.
- `--no-cooldown` disables the age gate but the batch still installs only the
  deferred names, never everything.

## What is classified as sudo-requiring

From the cask's artifacts in `brew info --json=v2` (verified against Homebrew
7.0.12 sources):

| Artifact | Why sudo |
|---|---|
| `pkg`, `keyboard_layout`, `suite` installers | `requires_sudo? == true` |
| `installer` | sudo when declared |
| `uninstall pkgutil`, `uninstall kext` | always sudo |
| `uninstall delete` | `rm` with `sudo: true`, unconditional |
| `uninstall script` | sudo when declared |
| `uninstall launchctl` | brew probes the system domain via sudo, even for user agents |

Formulae never need sudo (brew refuses to run as root). `app`, `binary`,
`quit`, `signal`, `trash` artifacts are sudo-free. A cask whose artifact
metadata is missing is deferred (fail closed), not guessed.

The rules live in `sudo_reasons()` / `plan_status()` in `lib/cooldown.py` and
are covered by `python3 lib/cooldown.py selftest`.

## Limits

- The classifier is artifact-based. A cask that grows a sudo path brew does
  not expose in JSON hits the askpass guard and fails fast — reported, never
  hung.
- `HOMEBREW_SUDO_CHECKED` is brew-internal. If a future brew ignores it, the
  cost is one extra prompt, not a hang.
- macOS system updates (`softwareupdate`) and Xcode installs are out of scope;
  `--system` only lists, `--xcode` remains explicitly interactive.

## Evidence (Homebrew 7.0.12 sources)

Why the classifier looks the way it does — verified against the installed brew:

| Source | Fact |
|---|---|
| `cask/artifact/pkg.rb`, `installer.rb`, `keyboard_layout.rb`, `suite.rb` | install via `requires_sudo?` (pkg runs `/usr/sbin/installer`, needs root) |
| `cask/artifact/app.rb`, `binary.rb`, `artifact.rb` | app moves / binary symlinks use plain `command.run` — no sudo |
| `cask/artifact/abstract_uninstall.rb` | `pkgutil` → `/usr/sbin/pkgutil --forget` (sudo), `kext` → `/sbin/kextunload` (sudo), `delete`/`script` → `system_command … sudo: true`; quit/signal/trash are sudo-free |
| `services/system.rb:160` | `launchctl print system/<label>` runs through sudo **unconditionally**, even for user-agent casks — so any `uninstall launchctl` stanza can prompt |
| `utils/sudo.sh` | every brew process runs `sudo --reset-timestamp` unless `HOMEBREW_SUDO_CHECKED` is set — the source of the repeated prompts |
| `system_command.rb:418` | with `SUDO_ASKPASS` set, brew calls `sudo -A` — the hook the exit-1 stub uses |

Design alternatives considered and rejected: sudoers `NOPASSWD` for brew commands
(permanent root hole, installer stanzas can run arbitrary scripts); `sudo -S` with a
piped password (password in process memory/pipe, `Defaults !visiblepw` blocks it);
`expect`-driven prompts (password in expect memory, fragile); a root daemon (large
attack surface). `--sudo-batch` keeps the credential entirely inside sudo.

## Related

- [`cooldown.md`](cooldown.md) — the age policy the batch still enforces
- [`homebrew-gate.md`](homebrew-gate.md) — how the gate classifies, including `sudo`
- [`operations.md`](operations.md) — cadence, logs, troubleshooting