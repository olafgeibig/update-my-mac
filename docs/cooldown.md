# Update cooldown

Every update path on this machine refuses to install a package version that has been
public for less than the cooldown window. The point is not the delay itself — it is that
a compromised release is usually detected and pulled again within hours to days, so a
short soak window means someone else finds out first.

Recent examples that a window would have (or did) cover:

| Incident | Time the malicious versions were live |
|---|---|
| axios (npm, March 2026) | ~2–3 h |
| TanStack Router/Start (npm, May 2026) | detected in minutes, deprecated in ~1.5 h |
| ChainDrop / keyv worm (npm, Aug 2026) | ~4 h of propagation |
| LiteLLM 1.82.7 / 1.82.8 (PyPI, March 2026) | days — bad versions stayed up for days before users were told |

## The two windows

```
COOLDOWN_HOURS        = 72    casks, third-party taps
COOLDOWN_HOURS_CORE   = 24    homebrew-core formulae
```

Both live in `~/.config/cooldown/cooldown.env` and are the only place they are set.

Why tiered:

- **homebrew-core formulae** go through a human-reviewed merge. A version cannot appear
  without a maintainer merging a PR; bottles are built by Homebrew CI from the reviewed
  formula, downloads are checksummed, and post-install scripts are off by default. A
  24 h window still blocks the hours-long smash-and-grab class, without holding security
  patches for `gh`, `ruby`, `llvm` or `pnpm` for three days.
- **Casks** run vendor installers (`pkg`, `installer`, `kext`) — often as root and
  unsandboxed. **Third-party taps** execute unreviewed Ruby. For those the failure mode
  is "code we never reviewed ran on this machine", so they get the full window.

The trade-off is deliberate: the safest source gets the least delay.

## Per-manager settings

Every manager except Homebrew enforces this itself, in its own global config. The script
does not wrap them — the config covers every caller, including agents and other scripts.

| Manager | Key | Unit | File | Value at 72 h |
|---|---|---|---|---|
| uv | `exclude-newer` | duration | `~/.config/uv/uv.toml` | `"72 hours"` |
| npm | `min-release-age` | **days** | `~/.npmrc` | `3` |
| pnpm | `minimumReleaseAge` | **minutes** | global pnpm `config.yaml` (`pnpm config set -g`) | `4320` |
| bun | `minimumReleaseAge` | **seconds** | `~/.bunfig.toml` | `259200` |
| deno | `minimumDependencyAge`, else npm's `.npmrc` | ISO-8601 / days | project `deno.json` | inherits `min-release-age` |
| cargo | `global-min-publish-age` | duration | `~/.cargo/config.toml` | `"3 days"` (needs Rust ≥ 1.100) |
| Homebrew | — (no native support) | — | `lib/cooldown.py` | merge date ≥ window |
| VS Code | `extensions.autoUpdateDelay` | **hours** | `settings.json` | `72` (auto-update only) |

The units really are different. Never copy a number from one row to another — that is
what `--cooldown-sync` exists for.

## Day-to-day commands

```bash
./update-my-mac.sh --report            # what would update, what is held, and why (changes nothing)
./update-my-mac.sh --cooldown-status   # effective setting per manager, incl. INEFFECTIVE states
./update-my-mac.sh --cooldown-sync     # re-derive every per-tool value from cooldown.env
./update-my-mac.sh --dry-run --brew    # print the commands instead of running them
```

`--cooldown-status` marks settings that look applied but are not:

```
npm   want: min-release-age = 3   have: 3        effective
cargo want: global-min-publish-age = "3 days"  PRE-STAGED (cargo 1.99.0 < 1.100)
```

That distinction matters: an npm older than 11.10 ignores `min-release-age` without an
error, and a cargo older than 1.100 ignores `global-min-publish-age`.

## Exemptions

One-off, for a security fix that cannot wait:

```bash
./update-my-mac.sh --bypass gh --brew      # exempt from the brew gate, this run only
./update-my-mac.sh --bypass litellm --uv   # upgrade exactly litellm with UV_EXCLUDE_NEWER=false
./update-my-mac.sh --bypass eslint --npm    # install eslint@latest with --min-release-age=0
./update-my-mac.sh --no-cooldown --brew    # disables the gate where the script can (brew, uv, npm)
```

`--bypass` is honored only when the manager flag is given explicitly: with `--brew`
the named packages are exempted in the gate plan; with `--uv`/`--npm` only the named
packages are touched, each with its gate disabled for that one call. It is not
persisted: it lives in a shell variable and (for brew) is recorded in the plan JSON
under `~/Library/Logs/update-my-mac/brew-cooldown-*.json` with
`"status": "bypass", "reason": "explicit bypass"`. A bypassed package also skips the
dependency rule below — that is the point of forcing it. `--bun` ignores `--bypass`
(bun gates resolution itself); use `bun add -g <pkg>@<version>` for an exact version.

With `--brew`, `--bypass` overrides the age window but **not** the sudo deferral: a
bypassed cask that needs root is still deferred and installed via `--sudo-batch`
([`sudo-batch.md`](sudo-batch.md)).

Permanent exemptions belong in the manager's own config, each with a date and a reason:

| Manager | Key |
|---|---|
| uv | `exclude-newer-package` |
| npm | `min-release-age-exclude[]` |
| pnpm | `minimumReleaseAgeExclude` |
| bun | `minimumReleaseAgeExcludes` |
| cargo | `[[allow.package]]` in `cooldown.toml` (via `cargo-cooldown`) |

A forgotten exemption silently weakens the gate for that package forever. Treat every
entry as debt.

## What this does not cover

- **First installs.** A cooldown gates updates. `npm i -g foo`, `uv tool install foo`,
  `brew install foo` all install a brand-new package immediately. Review before adding
  something new.
- **yarn 1.x (classic).** The age gate exists only in Berry (≥ 4.10, `npmMinimalAgeGate`).
  Projects with a yarn v1 lockfile are ungated.
- **pip on the system Python.** `uploaded-prior-to` needs pip ≥ 26.1; the system pip is
  far older. Python installs are expected to go through uv instead.
- **`go install` / `go get`.** No native age filter; only the Go binary itself (a brew
  formula) is gated.
- **Apple channels** (`mas`, Xcode, `softwareupdate`). No control; App Review is the only
  delay.
- **Install-time script execution.** A cooldown gives detection time, it does not sandbox
  anything. npm still runs lifecycle scripts unless told not to.

Dependency cooldowns, lockfiles and install-script policy are complements, not
substitutes.

## Related

- [`homebrew-gate.md`](homebrew-gate.md) — how the Homebrew gate is implemented
- [`sudo-batch.md`](sudo-batch.md) — root-requiring casks: deferral and the single-password batch
- [`operations.md`](operations.md) — logs, troubleshooting, emergencies
