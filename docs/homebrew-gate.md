# The Homebrew age gate

Homebrew has no user-facing minimum release age, and the request was declined upstream
([Homebrew/brew#21421](https://github.com/Homebrew/brew/issues/21421), closed *not
planned*, "Don't do that"). The maintainers' argument: every formula and cask change is
human-reviewed, bottles are built by Homebrew CI from the reviewed definition, downloads
are checksummed, post-install scripts are off by default, and a rolling-release manager
lives or dies on shipping security patches promptly. Homebrew runs its own cooldowns on
the *maintainer* side — it delays npm/PyPI/Bundler dependencies inside formula builds.

That reasoning is sound, which is why this gate is tiered rather than uniform:

- **homebrew-core formulae → `COOLDOWN_HOURS_CORE` (24 h).** The merge is already a trust
  decision; the extra days mostly delay patches.
- **casks and third-party taps → `COOLDOWN_HOURS` (72 h).** Casks execute vendor
  installers, often as root; taps execute unreviewed Ruby. There the delay is the only
  protection that exists.

## How a decision is made

For every package in `brew outdated --json=v2`:

1. **Find the definition file.** `brew info --json=v2 --formula|--cask <names>` returns
   `ruby_source_path` — `Formula/w/wget.rb` or `Casks/c/chatgpt.rb`. Casks must be keyed
   by `token`; their `name` field is a list of display names. Tapped formulae appear in
   `brew outdated` as `tap/name` but in `brew info` under plain `name`, so both keys are
   indexed.
2. **Find when that version was merged.**
   - `homebrew/core` and `homebrew/cask`: `gh api repos/Homebrew/<repo>/commits?path=<path>&per_page=1`
     (repo derived by replacing `/` in the tap name with `-`).
   - any other tap: `git -C "$(brew --repo <tap>)" log -1 --format=%cI -- <path>` — local,
     offline, no rate limit.
3. **Compare with the window** that applies to that package (see above).
4. **Write the plan** and hand the eligible names to `brew upgrade`:
   `brew upgrade <name> <name> …` — explicit targets only. A bare `brew upgrade` would
   defeat the gate instantly, which is why it must never reappear in the script.

## Classification

| Status | Meaning | Upgraded? |
|---|---|---|
| `eligible` | older than its window | yes |
| `held` | younger than its window | no |
| `held` | pulls a dependency that is itself held | no |
| `unknown` | merge date could not be established | **no** (fail closed) |
| `sudo` | age-eligible, but the upgrade needs root | **no** — deferred to `--sudo-batch` |
| `bypass` | named on the command line with `--bypass` | yes, regardless of age (root-requiring casks stay deferred) |

The `sudo` classification is artifact-based (`pkg` installers, `launchctl`,
`pkgutil`, `kext`, `delete`, `script` uninstalls); missing artifact metadata
fails closed. `--bypass` overrides the age window, not the sudo deferral.
Details and the single-password batch: [`sudo-batch.md`](sudo-batch.md).

## The dependency rule

`brew upgrade <formula>` also upgrades that formula's outdated dependencies, so an
eligible package can drag a young dependency in. Observed for real: `hatch` pulled
`certifi` and `uv`, both of which were held.

`apply_dependency_rule()` therefore demotes any eligible package whose own pending
dependency is held or unknown, iterated to a fixpoint (a demoted parent demotes its
parents). `dependencies` already rides along in the `brew info --json=v2` payload, so the
rule costs no extra API calls. Explicit `--bypass` packages are exempt.

## Fail-closed behaviour

Exit codes from `python3 lib/cooldown.py plan`:

| Code | Meaning | What the script does |
|---|---|---|
| 0 | plan computed | upgrade the eligible names |
| 2 | `brew outdated` / `brew info` unusable | **upgrade nothing**, print an error, return 2 |
| 3 | plan computed, ≥1 date unknown | upgrade the known-eligible names, warn about the rest |

"If in doubt, do nothing" is the whole point. A gate that silently falls back to
"upgrade anyway" is worse than no gate, because it looks like protection.

`brew outdated` is retried once: it can exit non-zero while a concurrent auto-update
holds its lock. Two failures in a row are treated as a real failure.

## Cost

- One API call per pending package, 8-way parallel. 76 pending packages resolve in ~18 s.
  Authenticated `gh` allows 5 000 requests/hour, so a daily run is nowhere near the limit.
- Results are cached in `~/.cache/update-my-mac/brew-age.json`, keyed
  `name|current_version`, 24 h TTL, so repeat runs cost nothing.
- Without `gh` the gate falls back to local tap clones and otherwise holds everything.

## Known limits

- **Casks that need sudo** are deferred, not upgraded, in unattended runs and
  installed together via `--sudo-batch` (one password prompt). The classifier
  is artifact-based; an unexpected sudo attempt fails fast through the askpass
  guard instead of prompting. See [`sudo-batch.md`](sudo-batch.md).
- **Bottle and revision rebuilds** (`formula: update 1.25.0_2 bottle`) move the commit
  date, so a rebuild of an old version is held like a new version. Conservative and
  correct: the artifact is new.
- **Dependencies that are not themselves pending** are not examined. If a dependency is
  already installed and up to date it is simply used; Homebrew may still install a
  *different* new dependency at upgrade time.
- **`brew cleanup` keeps 30 days** (`HOMEBREW_CLEANUP_MAX_AGE_DAYS=30`) instead of
  deleting every previous version, so a package that turns out to be broken after the
  window can still be rolled back.
- **The gate is only as good as the merge date.** A maintainer account compromise is not
  covered by any amount of waiting.

## Reading a plan

Every gated run writes `~/Library/Logs/update-my-mac/brew-cooldown-<stamp>.json`:

```json
{
  "cooldown_hours": 72,
  "cooldown_hours_core": 24,
  "counts": {"eligible": 13, "held": 24, "bypass": 0, "unknown": 0, "sudo": 6},
  "items": [
    {"name": "gh", "kind": "formula", "current": "2.103.1", "tap": "homebrew/core",
     "age_hours": 2.1, "threshold": 24, "status": "held", "deps": ["..."],
     "date": "2026-10-22T10:31:00Z", "source": "gh"}
  ]
}
```

`age_hours` against `threshold` explains every decision, and `source` says whether the
date came from the GitHub API, a local tap or the cache.
