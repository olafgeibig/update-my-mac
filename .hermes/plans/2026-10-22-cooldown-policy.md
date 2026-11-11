# 48-Hour Update Cooldown — Strategy and Implementation Plan

**Date:** 2026-10-22
**Author:** Hermes (zeus) for Olaf
**Status:** ✅ **Implemented on 2026-10-22, with the window raised to 72 hours**
**Scope:** every software source touched by `update-my-mac.sh` plus the sources found on this machine

> **Implementation note (2026-10-22).** Olaf decided on **72 h**, not 48 h. Everything in
> §4–§6 below is in place on this machine, derived from the single variable
> `COOLDOWN_HOURS=72` in `~/.config/cooldown/cooldown.env`:
>
> | Piece | Where | Value at 72 h |
> |---|---|---|
> | uv | `~/.config/uv/uv.toml` | `exclude-newer = "72 hours"` |
> | npm | `~/.npmrc` | `min-release-age=3` |
> | pnpm | `~/Library/Preferences/pnpm/config.yaml` | `minimumReleaseAge: 4320` |
> | bun | `~/.bunfig.toml` | `minimumReleaseAge = 259200` |
> | deno | inherits npm | 24 h built-in, widened to 72 h |
> | cargo | `~/.cargo/config.toml` | `global-min-publish-age = "3 days"`, pre-staged until Rust 1.100 |
> | VS Code | `Library/Application Support/Code/User/settings.json` | `extensions.autoUpdateDelay: 72` |
> | Homebrew | `lib/cooldown.py` + `update-my-mac.sh` | commit-date gate, fail-closed |
>
> Measured at implementation time: 77 pending upgrades → 38 eligible, 39 held.
> The npm PATH defect (§10.3) was fixed as well: `~/.brv-cli/bin` is now appended to
> `PATH` instead of prepended, so brew's npm 11.21.0 wins over the bundled npm 10.9.8.
>
> The rest of this document is the original 48 h analysis and the reasoning behind the
> design; treat "48" as "the threshold" wherever it appears.

## First real run (2026-10-22, 72 h window)

`./update-my-mac.sh --brew` planned 77 pending upgrades → **38 eligible, 39 held**, then
upgraded the eligible set. Result: **48 packages moved** (formulae incl. node, uv, rust,
openssl@3, python@3.13/3.14/3.15, llvm; casks incl. iterm2, obsidian, dropbox, fuse-t),
leaving **29 outdated: 4 eligible, 25 held**.

Two findings from that run, both fixed or documented:

1. **Dependency leak (fixed).** `brew upgrade <name>` also upgrades that formula's
   outdated dependencies: `hatch` pulled `certifi` and `uv` in although both were held.
   `lib/cooldown.py` now demotes any package whose own pending dependency is inside the
   window, iterated to a fixpoint (`apply_dependency_rule`, covered by
   `python3 lib/cooldown.py selftest`).
2. **Casks that need sudo stay pending (accepted).** `dropbox`, `fuse-t`, `proxyman`
   failed with `sudo: a terminal is required to read the password`; `onyx` hit leftover
   residue from the interrupted first attempt (`already an App at ...`). These four are
   the 4 packages still eligible — they need an interactive terminal.

Also surfaced: `pnpm` exists twice (Homebrew formula 12.14.0 installed but **unlinked**
because `/opt/homebrew/bin/pnpm` is a corepack shim pointing at pnpm 12.5.1). Both read
the same global `config.yaml`, so the cooldown applies either way. Resolving the
duplication is a separate decision: `brew link --overwrite pnpm` (brew-managed) or
`brew uninstall pnpm` (keep corepack's per-project `packageManager` pinning).

---

## 0. TL;DR

| Source | Native cooldown support? | What we do | Effort |
|---|---|---|---|
| **uv** (`uv tool upgrade`, litellm etc.) | ✅ `exclude-newer = "2 days"` | global `~/.config/uv/uv.toml` | 5 min |
| **npm** (global, `npx`) | ✅ `min-release-age = 2` (days), npm ≥ 11.10 | `~/.npmrc` via CLI; **also fix the npm PATH split** | 15 min |
| **pnpm** | ✅ `minimumReleaseAge: 2880` (minutes), default 1440 since v11 | global `~/.config/pnpm/config.yaml` | 5 min |
| **bun** | ✅ `[install] minimumReleaseAge = 172800` (seconds) | `~/.bunfig.toml` | 5 min |
| **deno** | ✅ default 24 h since 2.9; `minimumDependencyAge: "PT48H"` | global `deno.json` | 5 min |
| **Homebrew** (271 formulae, 60 casks, 15 taps) | ❌ declined upstream (feature request #21421 closed "not planned") | **commit-date gate** in the update script: only upgrade what was merged ≥ 48 h ago (verified working, see §5) | 2–4 h |
| **pip** (system Python 3.9) | ⚠️ `uploaded-prior-to` needs pip ≥ 26.1, we have 23.1 | do **not** retrofit pip — route Python installs through uv | — |
| **cargo** | ⚠️ stable in Rust **1.100 (2026-11-12)**; we run 1.99.0 | pre-stage `[registry] global-min-publish-age = "2 days"`, activate after 1.100 lands | 10 min + wait |
| **Go** | ❌ proposal only (golang/go#76485) | nothing installed via `go install` → no action, note the gap | — |
| **Ruby / gem** | ⚠️ Bundler 4.0.13+, RubyGems 4.1 (beta); we have Bundler 3.x | only if Ruby work starts; otherwise skip | — |
| **mas / App Store / Xcode** | ❌ | Apple review is the cooldown; no control possible | — |
| **macOS `softwareupdate`** | ❌ | Apple-signed, out of scope | — |
| **VS Code extensions** (106) | ⚠️ `extensions.autoUpdateDelay` (hours), only gates auto-updates | auto-update is already off — effectively manual | 1 min |
| **Claude Code plugins** | ⚠️ pinned version + git SHA | **stop wiping the plugin cache** in `update_plugins` | 10 min |

**Core finding:** 6 of the 9 ecosystems used here enforce 48 h natively in one config line. Homebrew is the only one that needs real engineering, and that gate I already prototyped against the live machine: of today's 76 pending upgrades (57 formulae + 19 casks), **32 are younger than 48 h and would have been held**, 44 would go through.

---

## 1. Inventory — what actually gets updated here

Verified on this machine, 2026-10-22.

### 1.1 What `update-my-mac.sh` does today

| Function | Commands | Real risk |
|---|---|---|
| `update_brew` | `brew update` → `brew upgrade` → `brew cleanup` | installs every pending formula **and cask** immediately; casks run vendor installers |
| `update_npm` | `brew upgrade npm` → `npm update -g` | resolves latest from npmjs on every run |
| `update_bun` | `bun upgrade` → `bun update -g` | same, for bun + 2 global packages |
| `update_uv` | `brew upgrade uv` → `uv tool upgrade --all` | **33 tools incl. litellm 1.105.0**, aider, docling, semgrep, mnemosyne, openviking |
| `update_plugins` | `rm -rf ~/.cache/opencode/node_modules`, `rm -rf ~/.claude/plugins/cache/*` | forces a fresh resolve/reinstall — the *opposite* of a cooldown |
| `update_appstore` | `mas upgrade` | Apple review window applies |
| `update_xcode` | `softwareupdate --install --all` | Apple |
| `update_system` | `softwareupdate --list` | Apple |
| `cleanup` | `npm cache clean --force`, `uv cache prune`, `brew cleanup` | destroys the old-version fallback |

### 1.2 Sources found on the box (some outside the script's reach)

```
brew      7.0.9-50     /opt/homebrew            271 formulae, 60 casks, 17 taps
npm       10.9.8  ⚠️   ~/.hermes/node/bin/npm    global prefix = ~/.brv-cli (0 packages!)
npm       11.21.0      /opt/homebrew/bin/npm     ← the one that supports min-release-age
pnpm      12.5.1       via corepack              no config yet
yarn      1.22.22      classic                   no age gate exists (Berry-only feature)
bun       1.4.3                                no bunfig yet
uv        0.13.0                               33 tools, no uv.toml
deno      2.9.7                                 default 24 h cooldown active
cargo     1.99.0                               no ~/.cargo/config.toml, ~/.cargo/bin empty
go        1.27.2                              ~/go/bin empty
ruby/gem  3.0.3.1 / Bundler 3.x                53 system gems
mas       10 apps incl. Xcode 26.4              App Store
ollama    0.15.6                               model pulls by tag
VS Code   106 extensions                       autoUpdate already "off"
claude   1 plugin (pinned: arscontexta 0.8.0 @ 2acfd5c)
```

⚠️ **Defect worth fixing in the same pass:** the `npm` in `PATH` is Hermes' bundled npm 10.9.8, while `npm root -g` points at `~/.brv-cli` — an empty directory. That means `npm update -g` in the script updates *nothing*, and the npm that would honour a cooldown config is only reachable as `/opt/homebrew/bin/npm`. Both read `~/.npmrc`, so the cooldown config lands regardless, but the update path itself is broken today.

---

## 2. Threat model — what 48 h buys, and what it does not

**Why 48 h is the right number for this machine:** recent incidents were live for hours, not days.

| Incident | Malicious window |
|---|---|
| LiteLLM 1.82.7 / 1.82.8 on PyPI (2026-03-24, via compromised Trivy CI) | ~6 days until v1.83.0 landed on a new pipeline; the bad versions were pulled after days, not hours |
| axios (2026-03) | ~2–3 h |
| TanStack Router/Start (2026-05) | detected in minutes, deprecated in ~1.5 h |
| ChainDrop / keyv npm worm (2026-08) | ~4 h of active propagation |
| ua-parser-js (2021) | ~4 h |

A 48 h floor kills every hours-long incident and buys a business day of detection for the multi-day ones — which is exactly LiteLLM's case, where the injected code lived for days before users were told. A 7-day floor would also have blocked LiteLLM 1.82.x entirely, but slows every tool down by a week. **48 h is the compromise; make it one variable so it can be raised later.**

**What it does not buy:**

- Attacks that dwell inside a legitimate release for longer than the window (LiteLLM-style CI compromise is the near-miss: 48 h would *not* have been enough if the bad versions had stayed up a week).
- Typosquatting / slopsquatting of packages you install for the first time. A cooldown only gates *updates*, not first installs.
- Anything that executes at install time from a package that already sat in the window. **Pair the cooldown with install-script policy** (npm `ignore-scripts` for globals is worth considering; `brew` already disables post-install scripts by default).
- Credential exposure after the fact — that is a secrets-hygiene problem, not a package-manager one.

---

## 3. Mechanism matrix

| Tool | Setting | Unit | Minimum version | Global location | Notes / traps |
|---|---|---|---|---|---|
| uv | `exclude-newer` | duration (`"2 days"`, `"48 hours"`, RFC3339) | 0.9.17 for relative | `~/.config/uv/uv.toml` or `UV_EXCLUDE_NEWER` | applies to `uv pip`, `uv sync`, `uv tool upgrade`; per-package `exclude-newer-package` |
| npm | `min-release-age` | **integer days** | **11.10.0** | `~/.npmrc` | `min-release-age-exclude[]` since 11.17; `NPM_CONFIG_MIN_RELEASE_AGE`; conflicts with `--before` |
| pnpm | `minimumReleaseAge` | **minutes** | 10.16; default 1440 since 11.0 | global `config.yaml` (`pnpm config set -g`) | since 12.3 an explicit value is **strict**: no fallback to older version, install fails instead |
| yarn | `npmMinimalAgeGate` | minutes or `"3d"` (day-suffix bug in old 4.x) | 4.10, default `1d` since 4.15 | `~/.yarnrc.yml` | **Berry only** — 1.22 classic has nothing |
| bun | `minimumReleaseAge` | **seconds** | 1.3.0 | `~/.bunfig.toml [install]` | bypassed when the version is already in `bun.lock` (oven-sh/bun#30525); `bunx` ignores it (#30748) |
| deno | `minimumDependencyAge` | ISO-8601 (`PT48H`), minutes, or RFC3339 | 2.6; 24 h default since 2.9 | `deno.json` | honors `min-release-age` from `.npmrc` since 2.8 |
| pip | `uploaded-prior-to` | ISO duration (`P2D`) | **26.1** (26.0 absolute only) | `~/.config/pip/pip.conf [install]` | no per-package exemptions |
| poetry | `solver.min-release-age` | days | 2.4 | `poetry config` | not installed here |
| cargo | `[registry] global-min-publish-age` | duration string | **Rust 1.100** (2026-11-12) | `~/.cargo/config.toml` | until then: `cargo-cooldown` crate (`cargo cooldown build`, `CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE`) |
| bundler | `cooldown` | days | 4.0.13 | `bundle config set --global cooldown 2` | per-source override in Gemfile; fails open on missing timestamps |
| gem | `--cooldown DAYS` / `:cooldown:` in `~/.gemrc` | days | 4.1 (beta) | `~/.gemrc` | shares settings with bundler |
| VS Code | `extensions.autoUpdateDelay` | **hours** | 1.125 | `settings.json` | gates only *updates*, not first installs; needs auto-update enabled |
| Homebrew | — | — | — | — | **not supported, will not be** (#21421 closed not-planned, MikeMcQuaid: "Don't do that") |
| Go | — | — | — | — | proposal only (#76485) |

Sources: `cooldowns.dev`, per-tool docs, Homebrew security docs, `Homebrew/brew#21421`, `rust-lang/cargo` RFC 3923 / PR #17335, `pnpm.io/settings`, `socket.dev/blog/rust-cargo-cooldowns`.

---

## 4. Phase 1 — native configuration (≈1 hour, do first)

All values derive from one shell variable, so raising to 7 days later is a one-line change.

```bash
# ~/.config/cooldown/cooldown.env  (sourced by update-my-mac.sh and by the shell profile)
COOLDOWN_HOURS=48
```

### 4.1 uv — this is the LiteLLM fix

```toml
# ~/.config/uv/uv.toml
exclude-newer = "48 hours"
```

Verify:
```bash
uv tool upgrade --all --dry-run          # expect "would upgrade"/no-op, never a <48h version
uv pip install --dry-run litellm         # resolves to the newest version older than 48 h
```
Also export `UV_EXCLUDE_NEWER="48 hours"` in `~/.zshrc` as a belt-and-braces measure for tools that call uv outside this config (e.g. `uvx`).

**Covers:** litellm, aider, docling, semgrep, mnemosyne, openviking and the other 27 uv tools — i.e. exactly the class of package that got hit in March.

### 4.2 npm

```bash
/opt/homebrew/bin/npm config set --location=user min-release-age 2    # DAYS (integer!)
/opt/homebrew/bin/npm config get min-release-age                      # -> "2"
```
Do **not** hand-edit `~/.npmrc` — it holds the npm auth token. Use the CLI so the token survives.

Separately (bug fix): put `/opt/homebrew/bin` ahead of `~/.hermes/node/bin` in `PATH`, or drop the stale global prefix:
```bash
npm config delete prefix        # with brew npm: removes the ~/.brv-cli prefix
```
Verify `npm --version` → 11.21.0 in a fresh shell.

### 4.3 pnpm

```bash
pnpm config set -g minimumReleaseAge 2880       # minutes
pnpm config get -g minimumReleaseAge            # -> 2880 (file: ~/.config/pnpm/config.yaml)
```
Consider also `minimumReleaseAgeExclude` for internal/private packages, and note the pnpm ≥12.3 strictness: if no version satisfies the cooldown, `pnpm install` **fails** instead of silently taking an older one. That is the behaviour we want, but it will surface as build breakage in projects that pin to a fresh release.

### 4.4 bun

```toml
# ~/.bunfig.toml
[install]
minimumReleaseAge = 172800        # seconds
# minimumReleaseAgeExcludes = ["@types/node"]   # optional
```
Caveat to accept knowingly: a version already recorded in a project's `bun.lock` installs without the gate, and `bunx` bypasses it.

### 4.5 deno

Deno 2.9 already applies 24 h. Widen to 48 h globally:
```json
// ~/.config/deno/deno.json   (or project deno.json)
{ "minimumDependencyAge": "PT48H" }
```
Verify with `deno info --json <pkg>` / `deno outdated --minimum-dependency-age=PT48H`.

### 4.6 cargo — pre-stage now, activate on 1.100

`~/.cargo/config.toml` (create; `~/.cargo/` currently holds no config):
```toml
[registry]
global-min-publish-age = "2 days"
```
On 1.99 this is an unknown key (warning only, no effect). Check after `rustup update`/brew delivers 1.100 on 2026-11-12:
```bash
cargo --version && cargo build 2>&1 | grep -i "unused config key"
```
Interim option, if Rust builds start happening before that: `cargo install cargo-cooldown` and use `cargo cooldown build` instead of `cargo build`. **Note:** `cargo-cooldown` is a subcommand, not a wrapper — plain `cargo build` stays ungated.

### 4.7 pip — do not retrofit

System pip is 23.1 (Apple Python 3.9); `uploaded-prior-to` needs 26.1. Options were: (a) upgrade system pip — touching Apple's Python, bad idea; (b) absolute-date config + hourly cron rewriting it (Seth Larson's pattern) — moving parts for an ecosystem that isn't used here. **Decision: route all Python installs through uv** (which is already where litellm and friends live). Add a guard in the script instead: if anyone runs `pip install`, print a warning pointing at `uv tool install`.

### 4.8 VS Code

```jsonc
"extensions.autoUpdate": "off",      // already set
"extensions.autoUpdateDelay": 48     // belt-and-braces if auto-update is ever re-enabled
```
First installs of a brand-new extension stay ungated — accept, or review before installing.

### 4.9 yarn / gem / go — explicit non-actions

- **yarn 1.22 (classic):** the age gate is Berry-only. Either migrate to Berry 4.15+ (then `npmMinimalAgeGate: 2880`) or accept that yarn projects are the one JS hole. Recommendation: check whether any active project actually uses yarn; if not, leave it and revisit on use.
- **gem/Bundler:** no native gate below Bundler 4.0.13. Skip until Ruby work appears.
- **go:** nothing installed with `go install`. If that changes, the only lever is lockfile discipline (`GOFLAGS=-mod=readonly`) plus a CI age check (`gomod-age`).

---

## 5. Phase 2 — Homebrew (the only real engineering)

### 5.1 Why there is no native setting

Homebrew declined a user-side minimum age (`#21421`, closed not-planned). MikeMcQuaid's argument: every formula/cask change is human-reviewed, bottles are built by Homebrew CI from the reviewed formula, post-install scripts are off by default, and the historical hit rate of malicious upstreams is orders of magnitude lower than the 0-day-patch cost. Homebrew instead applies a **1-day cooldown on npm/PyPI/Bundler dependencies inside its own formula builds** (April 2026) — i.e. the delay sits on the maintainer side.

Honest assessment for your machine:

- **homebrew-core formulae:** the residual risk is low (reviewed, checksummed, bottled, no post-install). A 48 h gate buys little but costs little.
- **casks:** different trust model — `pkg` and `installer script` stanzas run vendor code, often with sudo. 19 casks are pending right now. **This is where the gate earns its keep.**
- **the 17 third-party taps** (`adoptopenjdk`, `azure`, `charmbracelet`, `steipete`, `oven-sh`, `xdevplatform`, `anomalyco`, `olympus`… plus your own `olafgeibig`): no Homebrew review at all, arbitrary Ruby executed locally, gated only by `brew trust` (v6+). These are the weakest link on the machine and are *not* covered by "Homebrew has human review".

### 5.2 The gate: merge-date filter, verified working

Mechanism per pending package:
1. `brew outdated --json=v2` → names + installed/current versions (`casks[].name` is the token, not a display name).
2. `brew info --json=v2 --formula ...` / `--cask ...` (one call each) → `ruby_source_path`, e.g. `Formula/w/wget.rb` or `Casks/c/chatgpt.rb`.
3. `gh api "repos/Homebrew/homebrew-core/commits?path=Formula/w/wget.rb&per_page=1" --jq '.[0].commit.committer.date'` → when that version bump was merged.
4. `now - merge_date >= 48h` → eligible; else → hold and report the remaining time.

Measured today (76 items, 8-way parallel, ~18 s wall time):

```
total = 76   hold (<48h) = 32   eligible (>=48h) = 44
holds included:  duckdb 1.1 h · node 2.7 h · uv 3.7 h · mitmproxy 4.2 h
                 chatgpt 4.8 h · nss 7.0 h · firefox 40.4 h · certifi 47.9 h
```

That is the whole feature, and it already produces sane output: `uv` and `node` — the very packages that would immediately follow a fresh upstream release — get held, while month-old bumps go through.

Implementation notes that matter:

- **Rate limits:** authenticated `gh` = 5 000 req/h; worst case here is ~76 per run, daily cron → no issue. Add a `.cache/brew-age.json` keyed by `name:current_version` with a 24 h TTL so repeat runs are free.
- **Fail closed:** if `gh` is unauthenticated, errors, or a commit date is missing → **hold the package and say so**, never upgrade by default.
- **Batch the upgrade:** `brew upgrade <name> <name> …` with the explicitly filtered list. Never leave a bare `brew upgrade` in the script — it is the one command that silently defeats the gate.
- **`brew update` still runs first** (the filter needs current metadata).
- **Third-party taps:** read the merge date locally, `git -C "$(brew --repo <tap>)" log -1 --format=%cI -- <path>` — no API needed, works offline, and covers `olafgeibig/*`.
- **Bottle rebuilds** (`xxx: update 1.25.0_2 bottle`) count as new artifacts and will be held — conservative, acceptable.
- **`brew cleanup` stays**, but note it deletes the previous versions; with a 48 h gate the rollback window shrinks. Consider `HOMEBREW_CLEANUP_MAX_AGE_DAYS=30` instead of unconditional cleanup.
- **Dependency upgrades:** `brew upgrade foo` may also pull newer dependencies that are inside their own window. Residual risk, accepted (deps are bottle-pinned to the reviewed formula).

### 5.3 Adjacent hardening (cheap, high value)

```bash
brew trust --formula <name>      # trust per formula/cask instead of whole taps
brew untap <unused taps>         # 17 taps loaded locally = 17 review bypasses
```
Also worth an audit: `brew trust --json v1` to see what is currently trusted implicitly.

---

## 6. Phase 3 — wiring it into `update-my-mac.sh`

### 6.1 Design

- New section `# --- cooldown policy ---` near the top: `COOLDOWN_HOURS=${COOLDOWN_HOURS:-48}`, `COOLDOWN_BYPASS=""`, `COOLDOWN_ENFORCE=${COOLDOWN_ENFORCE:-1}`.
- New helper `cooldown_check <kind> <name> <version>` returning 0 (eligible) / 1 (hold) plus a human-readable age, so every update function reports uniformly.
- `update_brew` becomes: fetch outdated → classify → upgrade eligible → print a `held back (N)` block with ages → cleanup.
- `update_uv` / `update_npm` / `update_bun` stay one-liners (their own configs do the work) but gain a preflight `cooldown_preflight` that asserts the config is actually in place, and a postflight that greps the tool's output for versions outside the window.
- `update_plugins`: **drop the Claude Code cache wipe**, or gate it behind `--plugins --force`. Wiping a cache is a forced re-resolve and cannot be reconciled with a cooldown.
- New flags:
  - `--report` (alias `--cooldown-status`): show what would update, what is held, and why. No changes. This is the flag you actually run daily.
  - `--bypass <pkg>[,<pkg>]`: one-shot exemption for a security fix, logged.
  - `--no-cooldown`: whole run without the gate, logged loudly.
- Logging: every hold writes `[HOLD] <pkg> <version> age=12.3h` and the bypass writes `[BYPASS] <pkg> by=<user> reason=<text>` so there is an audit trail next to the existing LLM analysis.
- Exit code: `0` normal, `2` if the gate could not be evaluated (fail-closed → nothing upgraded).

### 6.2 Sketch (not applied)

```bash
cooldown_brew_outdated() {   # writes two newline-separated lists to a tmp file
  brew outdated --json=v2 | jq -r '
    (.formulae[] | ["formula", .name, .current_version, "homebrew-core"]),
    (.casks[]   | ["cask",   .name, .current_version, "homebrew-cask"]) | @tsv'
}

cooldown_merge_date() {      # kind name path repo -> epoch
  gh api "repos/Homebrew/$4/commits?path=$3&per_page=1" \
     --jq '.[0].commit.committer.date' | date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "%Y-%m-%dT%H:%M:%SZ" - +%s
}
```

(The prototype used Python for the same logic; shell-only is feasible but `jq` + `date` juggling is worse than a 40-line Python helper. Recommendation: `lib/cooldown.py`, invoked by the script, unit-testable.)

---

## 7. Bypass policy (so the gate does not become the problem)

| Situation | Action |
|---|---|
| Critical 0-day patch lands inside the window | `./update-my-mac.sh --bypass <pkg>`, then note it; the bypass is logged, not persisted |
| Whole run urgently needed | `COOLDOWN_HOURS=0 ./update-my-mac.sh --full` (loud warning + log line) |
| A package is permanently exempt | `min-release-age-exclude[]` (npm), `minimumReleaseAgeExclude` (pnpm), `minimumReleaseAgeExcludes` (bun), `exclude-newer-package` (uv), `npmPreapprovedPackages` (yarn) — **and document why, in the config itself** |
| Gate blocks a build | pnpm ≥12.3 fails hard by design; decide per project whether that is acceptable or whether the project pins an exempt version |

A forgotten exemption permanently weakens the gate. Every exemption gets a comment with date + reason.

---

## 8. Rollout

| Phase | Content | Effort | Risk |
|---|---|---|---|
| 1 | uv + npm (+PATH fix) + busted plugin wipe | 30 min | low, immediately protects the LiteLLM-class surface |
| 2 | pnpm + bun + deno + cargo pre-stage + VS Code delay | 30 min | low |
| 3 | Homebrew commit-date gate in the script, `--report` first, then enforcement | 2–4 h | medium — needs the gh dependency, fail-closed logic, and real-world testing over a week |
| 4 | tap hygiene (`brew trust`, untap), yarn decision, gem/Bundler if needed | 1 h | low |
| 5 | Re-tune: after 2–4 weeks, decide 48 h vs 72 h vs 7 d based on how often the gate blocked something you actually needed | — | — |

### Acceptance tests

| # | Command | Expected |
|---|---|---|
| 1 | `uv tool upgrade --all --dry-run` right after `uv` 0.x released <48 h ago | litellm/uv tools not upgraded to the brand-new version |
| 2 | `npm view litellm version` vs `npm install -g litellm --dry-run` under `min-release-age=2` | installed version ≤ 48 h older than `latest` |
| 3 | `pnpm config get -g minimumReleaseAge` | `2880` |
| 4 | `bun pm ls -g` after touching `minimumReleaseAge` | no package newer than the window |
| 5 | `./update-my-mac.sh --report` | lists eligible + held with ages; `uv`/`node` held when freshly bumped |
| 6 | `./update-my-mac.sh --brew` with one formula inside the window | that formula untouched, `[HOLD]` line in the log |
| 7 | `gh auth status` broken (simulate) → `--brew` | exit 2, nothing upgraded, explicit error |
| 8 | `--bypass duckdb` | duckdb upgraded, `[BYPASS]` in log, no config change |
| 9 | `./update-my-mac.sh --help` | new flags documented (AGENTS.md convention) |

---

## 9. Open decisions for you

| # | Question | Recommendation |
|---|---|---|
| 1 | 48 h or 72 h? | 48 h now; the config is one variable, revisit after a month |
| 2 | Homebrew gate at all, given upstream's position? | Yes — but mainly for **casks** and the **third-party taps**, not for core formulae |
| 3 | Drop the Claude Code plugin cache wipe? | Yes. It is incompatible with a cooldown and gains nothing |
| 4 | Kill the stale `~/.brv-cli` npm prefix? | Yes, but confirm nothing (Brave/opencode tooling?) depends on it first |
| 5 | Migrate yarn classic → Berry? | Only if a real project uses yarn; otherwise leave and note the gap |
| 6 | Where does the config live — script repo, or `~/.config/cooldown/`? | `~/.config/cooldown/cooldown.env` for the threshold; per-tool configs stay in their native locations |
| 7 | `lib/cooldown.py` as a helper, or pure zsh? | Python helper — testable, and `jq`+`date` in zsh is worse |

---

## 10. Appendix

### 10.1 Verified numbers (2026-10-22)

```
brew outdated: 57 formulae, 19 casks
48h gate:      32 held, 44 eligible
runtime:       ~18 s for 76 gh api lookups, 8-way parallel
gh version:    2.102.0 (authenticated)
```

### 10.2 Sources

- cooldowns.dev — cross-ecosystem reference, key names, units, per-package exemptions
- https://github.com/Homebrew/brew/issues/21421 — user-side minimum age, closed not-planned
- https://docs.brew.sh/Homebrew-Security-and-Supply-Chain — trust model, cask trust, cooldowns on riskier ecosystems
- https://pnpm.io/settings/dependency-resolution — `minimumReleaseAge*`, strictness since 12.3
- https://bun.com/docs/pm/cli/install — `minimumReleaseAge` in seconds; oven-sh/bun#30525, #30748
- https://pip.pypa.io/en/latest/user_guide — `--uploaded-prior-to` (26.0 / 26.1)
- https://doc.rust-lang.org/cargo/reference/config.html — `registry.global-min-publish-age` (1.100); RFC 3923; cargo PR #17335
- https://docs.astral.sh/uv/reference/settings/#exclude-newer
- https://docs.litellm.ai/blog/security-update-march-2026 — incident timeline used for the 48 h argument

### 10.3 Findings that are not about cooldowns but should not get lost

- `npm update -g` currently installs into `~/.brv-cli/lib/node_modules` (empty) → the npm branch of the script is a no-op.
- `~/.npmrc` holds an npm auth token: always edit it through the npm CLI.
- 17 third-party brew taps are loaded with no review process behind them.
- `update_plugins` forces a re-resolve of two plugin trees on every run — remove it or gate it.
