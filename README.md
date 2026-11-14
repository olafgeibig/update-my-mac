# update-my-mac

One command to update Homebrew, npm, pnpm, Bun, uv, App Store apps, Xcode and macOS itself —
without installing a package version that was published five minutes ago.

## Features

- **Update cooldown** — nothing younger than 72 h is installed. Enforced natively by uv,
  npm, pnpm, bun, deno and cargo, and by a commit-date gate for Homebrew.
- **Tiered Homebrew policy** — casks and third-party taps wait 72 h, human-reviewed
  `homebrew-core` formulae only 24 h, so security patches are not held for days.
- **Two profiles** — `--quick` (about 1–2 min) and `--full` (adds App Store, Xcode, macOS).
- **Ships its own gate** — `lib/cooldown.py` decides what Homebrew may upgrade and upgrades
  explicit targets only; a bare `brew upgrade` never runs.
- **Read-only report** — `--report` shows what would update, what is held, and why.
- **Sudo without the prompt flood** — root-requiring cask upgrades are deferred in
  unattended runs and installed together via `--sudo-batch` with one password prompt.
  The password never passes through the script.
- **Fail-closed** — if a release date cannot be established, the package is not touched.
- **Logging and analysis** — every run logs to `~/Library/Logs/update-my-mac/`, optionally
  summarised by Simon Willison's `llm` when installed.

## Quick start

```bash
chmod +x update-my-mac.sh
./update-my-mac.sh --report      # look first, change nothing
./update-my-mac.sh --quick       # gated updates (default with no flag)
./update-my-mac.sh --sudo-batch  # install the deferred sudo upgrades, one password prompt
./update-my-mac.sh --full        # add App Store, Xcode, macOS
```

## Update cooldown

Supply-chain attacks publish a malicious release and pull it again within hours. Every
update path here therefore refuses versions younger than the configured window.

| Manager | Enforced by |
|---|---|
| uv, npm, pnpm, bun, deno, cargo | each tool's own global config (`exclude-newer`, `min-release-age`, `minimumReleaseAge`, …) |
| Homebrew | `lib/cooldown.py` — merge date of the formula/cask must be older than the window |
| VS Code | `extensions.autoUpdateDelay` (auto-updates only) |

The windows live in one file:

```bash
cat ~/.config/cooldown/cooldown.env     # COOLDOWN_HOURS=72 / COOLDOWN_HOURS_CORE=24
./update-my-mac.sh --cooldown-sync      # re-derive every per-tool value from them
./update-my-mac.sh --cooldown-status    # what is actually in effect, per manager
```

Full policy, exemptions and limitations: [`docs/cooldown.md`](docs/cooldown.md).

## Requirements

- macOS with Zsh
- `python3` — runs the Homebrew gate
- `gh`, authenticated — the gate reads formula/cask merge dates through it
- Optional: Homebrew, Bun, uv, mas, `llm` for log analysis

Without `gh` the gate falls back to local tap clones and otherwise holds packages rather
than upgrading them. `--cooldown-status` shows what is effective.

## Installation

The script is not a single file: the gate lives in `lib/cooldown.py` and must sit next to
it. Install from a checkout (or a release tarball that contains `lib/`).

### One-line install (no checkout)

```bash
curl -fsSL https://raw.githubusercontent.com/olafgeibig/update-my-mac/main/install.sh | bash
```

It downloads the release tarball, verifies its SHA256, and installs the same tree as
below. Pin a version with `... | bash -s -- --ref v2026.11.14`. It refuses to install if
the checksum file is missing or does not match.

### From a checkout

```bash
git clone https://github.com/olafgeibig/update-my-mac.git
cd update-my-mac
chmod +x update-my-mac.sh
./update-my-mac.sh --install       # /usr/local/libexec tree + symlink in /usr/local/bin
update-my-mac --version            # version, helper state, installed layout
```

Layout:

```
/usr/local/libexec/update-my-mac/update-my-mac.sh
/usr/local/libexec/update-my-mac/lib/cooldown.py
/usr/local/libexec/update-my-mac/lib/sudo-askpass-defer.sh
/usr/local/bin/update-my-mac -> ../libexec/update-my-mac/update-my-mac.sh
```

The symlink is the only thing in `PATH`; the script resolves it and finds its helper. An
existing flat-file install is backed up to `update-my-mac.backup.<timestamp>` (the two
newest are kept), and `--install` refuses to run when `lib/cooldown.py` or
`lib/sudo-askpass-defer.sh` is missing — an incomplete tree would silently refuse every
Homebrew upgrade or lose the unattended sudo guard.

```bash
cd update-my-mac && git pull && ./update-my-mac.sh --install   # upgrade an existing install
./update-my-mac.sh --uninstall                                  # remove link and tree
```

Environment overrides: `UPDATE_MY_MAC_PREFIX` (default `/usr/local`) and
`UPDATE_MY_MAC_HELPER` (default `<script dir>/lib/cooldown.py`).

## Documentation

| Document | Read it when |
|---|---|
| [`docs/cooldown.md`](docs/cooldown.md) | you want the policy: windows, per-manager settings, exemptions, what is not covered |
| [`docs/homebrew-gate.md`](docs/homebrew-gate.md) | you need to know how the Homebrew gate decides, or you are changing it |
| [`docs/sudo-batch.md`](docs/sudo-batch.md) | a cask needs root: how deferral and the single-password batch work |
| [`docs/operations.md`](docs/operations.md) | a run failed, something is held unexpectedly, or you need an emergency bypass |
| [`AGENTS.md`](AGENTS.md) | you are an agent working on this repository |

## Contributing

Contributions are welcome — please keep the cooldown contract intact: no bare
`upgrade everything` call, no un-gated package manager, and
`python3 lib/cooldown.py selftest` green.
