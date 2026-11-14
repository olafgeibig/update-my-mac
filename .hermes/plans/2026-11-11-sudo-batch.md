# Sudo-deferred upgrades with a single-auth batch mode

Date: 2026-11-11
Status: implemented (this plan is the design record; user-facing docs live in `docs/sudo-batch.md`)

## Goal

Unattended runs never stop at a sudo prompt. Upgrades that need root are skipped,
listed in the report, and can be installed later in one batch that asks for the
password once. The password is never read, stored, logged or piped by the script.

## Evidence gathered on this machine (Homebrew 7.0.12, sudo 1.9.17p2)

- `system_command.rb:418`: when `SUDO_ASKPASS` is set, brew calls `sudo -A`.
  An askpass program that exits non-zero makes sudo fail immediately, no prompt.
  This is brew's documented mechanism (`env_config.rb`, `SUDO_ASKPASS`).
- `utils/sudo.sh`: brew's sudo probe runs `sudo --reset-timestamp` once per brew
  process — it *invalidates* cached credentials before the first real sudo call.
  Pre-authenticating with `sudo -v` alone therefore does not survive into brew.
  The probe is skipped when `HOMEBREW_SUDO_CHECKED=1` is already set (shell var).
- `services/system.rb:160`: `launchctl_run(sudo: true)` is a real sudo call.
  `uninstall_launchctl` iterates `[false, true]`, so **every cask with an
  `uninstall launchctl` stanza triggers sudo**, even for user-level agents.
- `abstract_uninstall.rb`: `delete` → `sudo: true` unconditional; `kext`,
  `pkgutil` → always sudo; `quit`/`signal` → never.
- `pkg.rb:16`: `requires_sudo? = true`; `installer.rb:87`: sudo when declared.
- Pending casks on this machine: 26, of which 6 need sudo
  (deepl, naps2, shutter-encoder, spotify, stats, visual-studio-code).
- Two latent gate bugs surfaced while spiking, both fixed as part of this work:
  1. `brew outdated/info --json=v2` can be polluted by auto-update banners on
     stdout → JSON parse fails → gate fails closed. Fix: `HOMEBREW_NO_AUTO_UPDATE=1`
     on the gate's brew calls.
  2. Some cask descriptions contain raw control characters → `json.loads` raises
     → all cask metadata lost. Fix: `strict=False`.

## Design

### Classification (lib/cooldown.py)

New status `sudo` between `eligible` and the upgrade list. Order of decisions:
bypass → unknown date → age-held → **sudo** → eligible. A cask that is
age-eligible but needs root becomes `sudo` (deferred), never `eligible`.
`--bypass` overrides the age window, not the sudo deferral (bypassed sudo casks
are deferred too and included in the batch).

`sudo_reasons(kind, artifacts)` — pure, offline-testable:
- formula → never sudo.
- cask install artifacts: `pkg`, `installer`, `keyboard_layout`, `suite` → sudo.
- cask uninstall directives: `pkgutil`, `kext`, `launchctl`, `delete`, `script` → sudo.
  (`launchctl` included unconditionally: brew's probe itself invokes sudo.)
- cask with missing artifact metadata → sudo ("artifacts unknown", fail closed).

Plan output: `--sudo-out <file>` (names, one per line), counts gain `sudo`,
report gains a "Deferred, needs sudo" bucket with the `--sudo-batch` hint.
The dependency rule is unchanged (formulae only; casks are never dependencies).

### Unattended guard (update-my-mac.sh + lib/sudo-askpass-defer.sh)

Normal `brew upgrade` runs with `SUDO_ASKPASS=lib/sudo-askpass-defer.sh`.
The helper prints a marker to stderr and exits 1 — it contains no secrets and
reads nothing. Any *unexpected* sudo attempt (misclassification) fails fast
instead of prompting; the run continues and the failure is reported with a
pointer to `--sudo-batch`. Pre-classification remains the primary mechanism;
the guard is the safety net.

### Batch mode (`--sudo-batch`)

1. Refuses to run without a real terminal (`[[ -t 0 && -t 1 ]]`).
2. `brew update`, then the same cooldown gate plan with `--sudo-out`.
   **The cooldown stays enforced** — the batch upgrades exactly the deferred
   names, nothing else, nothing younger than the window.
3. `sudo -v` — the one password prompt, handled by sudo itself on the tty.
   The script never sees the password. `sudo -n true` afterwards detects
   `timestamp_timeout=0` sudoers and warns that caching is disabled.
4. Keep-alive: background `sudo -n true` every 50 s so long downloads do not
   expire the ticket (the likely cause of the observed 7 prompts). Killed on
   exit/interrupt; `sudo -k` afterwards closes the root window immediately.
5. `HOMEBREW_SUDO_CHECKED=1` exported so brew skips its timestamp-reset probe
   (brew-internal; if a future brew ignores it, the cost is one extra prompt —
   graceful degradation, verified against 7.0.12 source).
6. One `brew upgrade <name> …` invocation for the whole batch, logged as usual.
   sudo's prompt goes to /dev/tty, never into the captured log stream.

### Security properties

- No `sudo -S`, no password in argv/env/files/logs; askpass helper is a no-secret
  exit-1 stub. sudo's own timestamp store (root-owned) is the only credential cache.
- Keep-alive only runs `sudo -n true` (non-interactive, no password).
- `sudo -k` + kill of the keep-alive on every exit path (trap INT/TERM).
- Batch is tty-only; cooldown is never bypassed by the batch path.

## Files changed

- `lib/cooldown.py` — classifier, `sudo` status, `--sudo-out`, report bucket,
  selftest cases, JSON robustness fixes.
- `lib/sudo-askpass-defer.sh` — new, exit-1 askpass stub.
- `update-my-mac.sh` — guard on normal upgrades, `sudo_batch()`, `--sudo-batch`
  flag, help text, install/uninstall deploy the new lib file.
- `docs/sudo-batch.md` — new; `docs/homebrew-gate.md`, `docs/operations.md`,
  `README.md` — updated; `install.sh` + `.github/workflows/release.yml` package
  the stub. `AGENTS.md` update pending approval; `CHANGELOG.md` is
  release-generated and deliberately untouched.

## Validation

- `python3 lib/cooldown.py selftest` (extended: classifier, precedence, bypass).
- `zsh -n update-my-mac.sh`; `shellcheck` if available.
- `--help`, `--report` (real gate, read-only), `--dry-run --brew`,
  `--dry-run --sudo-batch`.
- Guard probe: `SUDO_ASKPASS=lib/sudo-askpass-defer.sh sudo -A true` → rc 1,
  no prompt (testable without a password).
- The real batch needs the user's password once: `update-my-mac --sudo-batch`.

## Risks / limits

- Classifier is artifact-based; a cask that gains a sudo path brew does not
  expose in JSON would hit the askpass guard and fail fast (reported, not hung).
- `trash` uninstall is treated as non-sudo (Finder scripting); guard covers it.
- `HOMEBREW_SUDO_CHECKED` is brew-internal; worst case one extra prompt.
- Formulae never need sudo; `softwareupdate`/`mas` paths are out of scope here
  (`--system` only lists; `--xcode` install remains explicitly interactive).