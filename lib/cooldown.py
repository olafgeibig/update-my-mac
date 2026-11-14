#!/usr/bin/env python3
"""Cooldown (minimum release age) support for update-my-mac.

Homebrew has no user-facing minimum release age and declined the feature upstream
(Homebrew/brew#21421). This helper builds one client-side: a package may only be
upgraded once the version bump has been merged for at least COOLDOWN_HOURS hours.

Subcommands
-----------
plan    classify pending Homebrew upgrades and write an eligible-targets list
status  show the configured cooldown per package manager and whether it is effective
sync    derive every per-tool value from one threshold in hours

Statuses: eligible, held (inside the age window), unknown (date not established,
held), bypass (explicit exception), sudo (age-eligible but needs root - deferred
to `update-my-mac --sudo-batch`, never upgraded unattended).

Exit codes (plan)
-----------------
0  plan computed normally
2  could not evaluate Homebrew state at all  -> caller must upgrade nothing
3  plan computed, but >=1 release date was unknown (those packages were held)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

CACHE_TTL = 24 * 3600  # re-check a known package version at most once a day
CACHE_PATH = os.path.expanduser("~/.cache/update-my-mac/brew-age.json")
VSCODE_SETTINGS = os.path.expanduser(
    "~/Library/Application Support/Code/User/settings.json"
)
COOLDOWN_ENV = os.path.expanduser("~/.config/cooldown/cooldown.env")


# --------------------------------------------------------------------------- utils


def run(
    cmd: list[str] | str,
    shell: bool = False,
    timeout: int = 120,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    """Run a command; return (returncode, stdout, stderr) as separate streams.

    Never merge the two: brew writes deprecation warnings to stderr, and gluing
    them onto stdout turns valid JSON into unparsable text.
    """
    full_env = None
    if env:
        full_env = dict(os.environ)
        full_env.update(env)
    try:
        p = subprocess.run(
            cmd,
            shell=shell,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=full_env,
        )
        return p.returncode, p.stdout or "", p.stderr or ""
    except (subprocess.TimeoutExpired, FileNotFoundError) as exc:
        return 127, "", str(exc)


# brew may run auto-update even for read-only commands and print its banners on
# *stdout*, corrupting --json output. The gate's brew calls must never trigger
# that (nor env hints inside the JSON).
BREW_READONLY_ENV = {"HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ENV_HINTS": "1"}


def load_cache() -> dict:
    try:
        with open(CACHE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_cache(cache: dict) -> None:
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
    tmp = CACHE_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(cache, fh, indent=1, sort_keys=True)
    os.replace(tmp, CACHE_PATH)


def run_retry(
    cmd: list[str],
    timeout: int = 300,
    attempts: int = 2,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str]:
    """brew occasionally fails transiently (lock held by a concurrent auto-update)."""
    rc, out, err = 1, "", ""
    for attempt in range(attempts):
        rc, out, err = run(cmd, timeout=timeout, env=env)
        if rc == 0:
            return rc, out, err
        if attempt + 1 < attempts:
            time.sleep(3)
    return rc, out, err


def parse_iso(value: str) -> float | None:
    value = (value or "").strip()
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value).astimezone(timezone.utc).timestamp()
    except ValueError:
        return None


def human_age(hours: float) -> str:
    if hours < 0:
        return "future"
    if hours < 1:
        return f"{hours * 60:.0f}m"
    if hours < 48:
        return f"{hours:.1f}h"
    return f"{hours / 24:.1f}d"


# --------------------------------------------------------------------- brew lookup


def brew_outdated() -> tuple[int, list[dict]]:
    rc, out, err = run_retry(["brew", "outdated", "--json=v2"], env=BREW_READONLY_ENV)
    if rc != 0:
        sys.stderr.write(
            f"brew outdated failed (rc={rc}): {(err or out).strip()[:600]}\n"
        )
        return rc, []
    try:
        # strict=False: cask descriptions can contain raw control characters.
        data = json.loads(out, strict=False)
    except ValueError as exc:
        sys.stderr.write(f"brew outdated returned unparsable JSON: {exc}\n")
        return 2, []

    items: list[dict] = []
    for entry in data.get("formulae", []):
        items.append(
            {
                "kind": "formula",
                "name": entry["name"],
                "current": entry.get("current_version", ""),
                "installed": ", ".join(entry.get("installed_versions", [])),
            }
        )
    for entry in data.get("casks", []):
        name = entry.get("name")
        if isinstance(name, list):  # casks: name may be a list of display names
            name = name[0] if name else entry.get("token")
        items.append(
            {
                "kind": "cask",
                "name": name,
                "current": entry.get("current_version", ""),
                "installed": ", ".join(entry.get("installed_versions", [])),
            }
        )
    return 0, items


def brew_info(items: list[dict]) -> tuple[int, dict[str, dict]]:
    """name -> {path, tap} for every pending package."""
    meta: dict[str, dict] = {}
    rc_any = 0
    for kind, flag in (("formula", "--formula"), ("cask", "--cask")):
        names = [i["name"] for i in items if i["kind"] == kind]
        if not names:
            continue
        rc, out, err = run_retry(
            ["brew", "info", "--json=v2", flag, *names], env=BREW_READONLY_ENV
        )
        if rc != 0:
            rc_any = rc
            continue
        try:
            data = json.loads(out, strict=False)
        except ValueError:
            rc_any = 2
            continue
        for entry in data.get("formulae" if kind == "formula" else "casks", []):
            # casks expose the stable identifier as `token`; `name` is a list of display names.
            # Formulae from a tap are reported by `brew outdated` as "tap/name", while
            # `brew info` keys them by plain `name` - index both, or tapped formulae
            # (e.g. oven-sh/bun/bun) end up with no definition path and are held forever.
            keys: list[str] = []
            primary = entry.get("token") if kind == "cask" else entry.get("name")
            if isinstance(primary, list):
                primary = primary[0] if primary else None
            for candidate in (primary, entry.get("full_name")):
                if isinstance(candidate, str) and candidate and candidate not in keys:
                    keys.append(candidate)
            if not keys:
                continue
            record = {
                "path": entry.get("ruby_source_path") or "",
                "tap": entry.get("tap") or "",
                "deps": entry.get("dependencies") or [],
                # casks only: artifact list decides whether an upgrade needs sudo.
                # Keep None (absent) distinct from [] (present, empty) so the
                # classifier can fail closed on missing metadata.
                "artifacts": entry.get("artifacts") if kind == "cask" else None,
            }
            for key_name in keys:
                meta[key_name] = record
    return rc_any, meta


def gh_ready() -> bool:
    if not shutil.which("gh"):
        return False
    rc, _, _ = run(["gh", "auth", "status"], timeout=30)
    return rc == 0


def date_via_gh(repo: str, path: str) -> tuple[float | None, str]:
    rc, out, err = run(
        [
            "gh",
            "api",
            f"repos/Homebrew/{repo}/commits?path={path}&per_page=1",
            "--jq",
            ".[0].commit.committer.date",
        ],
        timeout=60,
    )
    if rc != 0:
        detail = (err or out).strip()
        return None, detail.splitlines()[0] if detail else "gh api failed"
    ts = parse_iso(out.strip().splitlines()[0] if out.strip() else "")
    return (ts, "" if ts else "unparsable date")


def date_via_git(tap: str, path: str) -> tuple[float | None, str]:
    rc, repo, _ = run(["brew", "--repo", tap], timeout=60)
    repo = repo.strip()
    if rc != 0 or not repo or not os.path.isdir(repo):
        return None, f"tap {tap} not available locally"
    rc, out, _ = run(
        ["git", "-C", repo, "log", "-1", "--format=%cI", "--", path], timeout=60
    )
    ts = parse_iso(out.strip().splitlines()[0] if out.strip() else "")
    return (ts, "" if ts else "no git history for path")


def resolve_dates(
    items: list[dict], meta: dict[str, dict], use_cache: bool
) -> tuple[dict[str, dict], int]:
    """Attach {date, source, error} to every item. Returns (by_name, failed_count)."""
    cache = load_cache() if use_cache else {}
    now = time.time()
    have_gh = gh_ready()
    results: dict[str, dict] = {}
    to_lookup: list[dict] = []

    for item in items:
        info = meta.get(item["name"], {})
        item["path"] = info.get("path", "")
        item["tap"] = info.get("tap", "")
        key = f"{item['name']}|{item['current']}"
        cached = cache.get(key)
        if use_cache and isinstance(cached, dict) and now - cached.get("ts", 0) < CACHE_TTL:
            results[item["name"]] = {
                "date": cached.get("date"),
                "source": "cache",
                "error": "",
            }
        elif not item["path"]:
            results[item["name"]] = {
                "date": None,
                "source": "none",
                "error": "no definition path from brew info",
            }
        else:
            to_lookup.append(item)

    def lookup(item: dict) -> tuple[str, dict]:
        tap = item["tap"] or ""
        if tap.startswith("homebrew/") and have_gh:
            repo = tap.replace("/", "-")  # homebrew/core -> homebrew-core
            ts, err = date_via_gh(repo, item["path"])
            src = "gh"
            if ts is None:  # fall through to local git when the API fails
                ts, err2 = date_via_git(tap, item["path"])
                src = "git"
                err = err2 or err
        else:
            ts, err = date_via_git(tap, item["path"]) if tap else (None, "unknown tap")
            src = "git"
        return item["name"], {"date": ts, "source": src, "error": err}

    if to_lookup:
        with ThreadPoolExecutor(max_workers=8) as pool:
            for name, res in pool.map(lookup, to_lookup):
                results[name] = res

    if use_cache:
        for item in to_lookup:
            res = results.get(item["name"], {})
            if res.get("date"):
                cache[f"{item['name']}|{item['current']}"] = {
                    "ts": now,
                    "date": res["date"],
                }
        # drop entries whose package no longer has that pending version
        alive = {f"{i['name']}|{i['current']}" for i in items}
        cache = {k: v for k, v in cache.items() if k in alive}
        save_cache(cache)

    failed = sum(1 for r in results.values() if not r.get("date"))
    return results, failed


# ------------------------------------------------------------------------ commands


def threshold_for(item: dict, hours: float, hours_core: float) -> float:
    """Pick the cooldown window for one pending package.

    homebrew-core formulae get the shorter window: a human maintainer reviews every
    merge, bottles are built by Homebrew CI from the reviewed formula, downloads are
    checksummed and post-install scripts are off by default - so the extra days buy
    little and only delay security patches (gh, ruby, llvm, pnpm ...).
    Casks run vendor installers, often as root; third-party taps run unreviewed Ruby.
    Those keep the full window.
    """
    if item.get("kind") == "formula" and item.get("tap") in ("homebrew/core", ""):
        return hours_core
    return hours


# Artifact types whose install/uninstall path invokes sudo. Verified against
# Homebrew 7.0.12 sources (cask/artifact/*.rb, services/system.rb):
#   pkg, keyboard_layout, suite  -> requires_sudo? == true
#   installer                    -> sudo when declared (manual is interactive anyway)
#   uninstall pkgutil / kext     -> always sudo
#   uninstall delete             -> rm with sudo: true, unconditional
#   uninstall script             -> sudo when declared
#   uninstall launchctl          -> probes `launchctl print system/<label>` via
#                                   sudo even when no system daemon exists, so
#                                   ANY launchctl stanza means a sudo call.
# quit/signal/trash and plain app/binary artifacts never sudo.
SUDO_INSTALL_ARTIFACTS = {"pkg", "installer", "keyboard_layout", "suite"}
SUDO_UNINSTALL_DIRECTIVES = {"pkgutil", "kext", "launchctl", "delete", "script"}


def sudo_reasons(kind: str, artifacts: list | None) -> list[str]:
    """Why upgrading this package would invoke sudo ([] = sudo-free).

    Formulae never need sudo (brew refuses to run as root). For casks the
    artifact list from `brew info --json=v2` decides; missing metadata fails
    closed (deferred rather than risking an unattended prompt).
    """
    if kind != "cask":
        return []
    if artifacts is None:
        return ["cask artifacts unknown"]
    reasons: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue  # bare strings are app/binary targets - sudo-free
        for key, value in artifact.items():
            if key in SUDO_INSTALL_ARTIFACTS:
                reasons.append(f"{key} installer")
            elif key == "uninstall" and isinstance(value, list):
                for directive in value:
                    if isinstance(directive, dict):
                        for name in directive:
                            if name in SUDO_UNINSTALL_DIRECTIVES:
                                reasons.append(f"uninstall {name}")
    # dedupe, keep order
    return list(dict.fromkeys(reasons))


def plan_status(
    name: str,
    kind: str,
    ts: float | None,
    age: float | None,
    limit: float,
    bypass: set[str],
    artifacts: list | None,
) -> tuple[str, str]:
    """One package's classification. Order: bypass > unknown date > age > sudo.

    `sudo` means age-eligible but root-requiring: deferred to `--sudo-batch`,
    never upgraded unattended. --bypass overrides the age window, not the sudo
    deferral (a bypassed sudo cask is deferred too and joins the batch).
    """
    was_bypass = name in bypass
    if was_bypass:
        status, reason = "bypass", "explicit bypass"
    elif ts is None:
        return "unknown", "release date unknown"
    elif age is not None and age >= limit:
        status, reason = "eligible", ""
    else:
        return "held", ""
    reasons = sudo_reasons(kind, artifacts)
    if reasons:
        prefix = "explicit bypass; " if was_bypass else ""
        return "sudo", prefix + ", ".join(reasons)
    return status, reason


def cmd_plan(args: argparse.Namespace) -> int:
    hours = float(args.hours)
    hours_core = float(args.hours_core) if args.hours_core is not None else hours
    bypass = {b.strip() for b in (args.bypass or "").split(",") if b.strip()}
    now = time.time()

    rc, items = brew_outdated()
    if rc != 0:
        print("ERROR: 'brew outdated' failed - cannot evaluate the cooldown gate", file=sys.stderr)
        return 2
    if not items:
        _write_plan(args, hours, hours_core, [], 0, 0)
        print("Nothing is outdated. Homebrew is already within the cooldown policy.")
        return 0

    rc_info, meta = brew_info(items)
    if rc_info != 0 and not meta:
        print("ERROR: 'brew info' failed - cannot evaluate the cooldown gate", file=sys.stderr)
        return 2

    dates, failed = resolve_dates(items, meta, use_cache=not args.no_cache)

    plan_items: list[dict] = []
    for item in items:
        info = dates.get(item["name"], {})
        ts = info.get("date")
        age = (now - ts) / 3600 if ts else None
        limit = threshold_for(item, hours, hours_core)
        item_meta = meta.get(item["name"]) or {}
        status, reason = plan_status(
            item["name"],
            item["kind"],
            ts,
            age,
            limit,
            bypass,
            item_meta.get("artifacts"),
        )
        if status == "unknown":
            reason = info.get("error") or reason
        plan_items.append(
            {
                **item,
                "threshold": limit,
                "date": (
                    datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    if ts
                    else None
                ),
                "age_hours": round(age, 2) if age is not None else None,
                "status": status,
                "reason": reason,
                "source": info.get("source", "none"),
                "deps": item_meta.get("deps", []),
            }
        )

    apply_dependency_rule(plan_items)

    _write_plan(args, hours, hours_core, plan_items, failed, len(meta))
    _print_report(hours, hours_core, plan_items)
    return 3 if failed else 0


def apply_dependency_rule(plan_items: list[dict]) -> None:
    """Hold a package whose own pending dependency is still inside the window.

    `brew upgrade <formula>` also pulls that formula's outdated dependencies, so an
    eligible package with a young dependency would drag the young version in anyway.
    Fixpoint over pending edges: a demoted parent can demote its own parents.
    """
    pending = {i["name"]: i for i in plan_items if i["kind"] == "formula"}
    changed = True
    while changed:
        changed = False
        for item in plan_items:
            if item["status"] != "eligible":
                continue
            for dep in item.get("deps", []):
                blocker = pending.get(dep)
                if blocker and blocker["status"] in ("held", "unknown"):
                    item["status"] = "held"
                    item["reason"] = f"pulls dependency {dep}, which is inside the window"
                    changed = True
                    break


def _write_plan(
    args: argparse.Namespace,
    hours: float,
    hours_core: float,
    items: list[dict],
    failed: int,
    info_count: int,
) -> None:
    eligible = sorted(i["name"] for i in items if i["status"] in ("eligible", "bypass"))
    sudo_deferred = sorted(i["name"] for i in items if i["status"] == "sudo")
    if args.json_out:
        os.makedirs(os.path.dirname(args.json_out), exist_ok=True)
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(
                {
                    "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "cooldown_hours": hours,
                    "cooldown_hours_core": hours_core,
                    "lookup_failures": failed,
                    "counts": {
                        s: sum(1 for i in items if i["status"] == s)
                        for s in ("eligible", "held", "bypass", "unknown", "sudo")
                    },
                    "items": items,
                },
                fh,
                indent=1,
            )
    if args.eligible_out:
        os.makedirs(os.path.dirname(args.eligible_out), exist_ok=True)
        with open(args.eligible_out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(eligible) + ("\n" if eligible else ""))
    if args.sudo_out:
        os.makedirs(os.path.dirname(args.sudo_out), exist_ok=True)
        with open(args.sudo_out, "w", encoding="utf-8") as fh:
            fh.write("\n".join(sudo_deferred) + ("\n" if sudo_deferred else ""))


def _print_report(hours: float, hours_core: float, items: list[dict]) -> None:
    def bucket(status: str) -> list[dict]:
        return [i for i in items if i["status"] == status]

    eligible, held, unknown, bypass, sudo_deferred = (
        bucket("eligible"),
        bucket("held"),
        bucket("unknown"),
        bucket("bypass"),
        bucket("sudo"),
    )
    if hours_core != hours:
        print(f"Cooldown {hours:g}h (homebrew-core {hours_core:g}h) - Homebrew plan")
    else:
        print(f"Cooldown {hours:g}h - Homebrew plan")
    print(f"  outdated : {len(items)}")
    print(f"  eligible : {len(eligible)}")
    print(f"  held     : {len(held)}")
    if sudo_deferred:
        print(f"  sudo     : {len(sudo_deferred)}  (deferred - needs root, run: update-my-mac --sudo-batch)")
    if bypass:
        print(f"  bypassed : {len(bypass)}")
    if unknown:
        print(f"  unknown  : {len(unknown)}  (held - release date not established)")
    print()

    if sudo_deferred:
        print(f"Deferred, needs sudo ({len(sudo_deferred)}) - install together with: update-my-mac --sudo-batch")
        for item in sorted(sudo_deferred, key=lambda i: i["name"]):
            print(f"  {item['name']:<24} {item['kind']:<8} {item['current']:<18} {item['reason']}")
        print()

    if bypass:
        print("Bypassed for this run:")
        for item in sorted(bypass, key=lambda i: i["name"]):
            print(f"  {item['name']:<24} {item['kind']:<8} {item['current']}")
        print()

    if held:
        print(f"Held back ({len(held)}):")
        for item in sorted(held, key=lambda i: i["age_hours"] or 0):
            age = human_age(item["age_hours"] or 0)
            if item.get("reason"):
                print(
                    f"  {item['name']:<24} {item['kind']:<8} {item['current']:<18} {age:>6} old, {item['reason']}"
                )
            else:
                left = human_age((item.get("threshold") or hours) - (item["age_hours"] or 0))
                print(
                    f"  {item['name']:<24} {item['kind']:<8} {item['current']:<18} {age:>6} old, {left:>5} to go"
                )
        print()

    if unknown:
        print(f"Held back, date unknown ({len(unknown)}):")
        for item in sorted(unknown, key=lambda i: i["name"]):
            print(f"  {item['name']:<24} {item['kind']:<8} {item['current']:<18} {item['reason']}")
        print()

    if eligible:
        names = ", ".join(i["name"] for i in sorted(eligible, key=lambda i: i["name"]))
        print(f"Eligible ({len(eligible)}): {names}")


def cmd_status(args: argparse.Namespace) -> int:
    hours = float(args.hours)
    days = max(1, round(hours / 24))
    minutes = int(hours * 60)
    seconds = int(hours * 3600)
    rows: list[tuple[str, str, str, str]] = []

    # uv
    uv_toml = os.path.expanduser("~/.config/uv/uv.toml")
    uv_val = _grep(uv_toml, r"^\s*exclude-newer\s*=\s*(.+)$")
    rows.append(("uv", f'exclude-newer = "{hours:g} hours"', uv_val or "MISSING", "resolution"))

    # npm
    npm_bin = _npm_binary()
    npm_ver = ""
    if npm_bin:
        _, npm_out, _ = run([npm_bin, "--version"], timeout=30)
        npm_ver = (npm_out.strip().splitlines() or ["?"])[0] if npm_out.strip() else "?"
    if npm_bin:
        _, npm_val, _ = run([npm_bin, "config", "get", "min-release-age"], timeout=30)
    else:
        npm_val = ""
    support = "effective" if _version_ge(npm_ver, "11.10.0") else f"IGNORED (npm {npm_ver} < 11.10)"
    rows.append(("npm", f"min-release-age = {days}", npm_val.strip() or "MISSING", support))

    # pnpm
    _, pnpm_val, _ = run(["pnpm", "config", "get", "-g", "minimumReleaseAge"], timeout=30)
    rows.append(("pnpm", f"minimumReleaseAge = {minutes}", pnpm_val.strip() or "MISSING", "resolution"))

    # bun
    bun_val = _grep(os.path.expanduser("~/.bunfig.toml"), r"^\s*minimumReleaseAge\s*=\s*(\d+)")
    rows.append(("bun", f"minimumReleaseAge = {seconds}s", bun_val or "MISSING", "resolution"))

    # cargo
    cargo_val = _grep(os.path.expanduser("~/.cargo/config.toml"), r"^\s*global-min-publish-age\s*=\s*(.+)$")
    _, cargo_out, _ = run(["cargo", "--version"], timeout=30)
    cargo_tokens = cargo_out.replace("cargo ", "").split()
    cargo_num = cargo_tokens[0] if cargo_tokens else ""
    cargo_ok = _version_ge(cargo_num, "1.100.0")
    rows.append(
        ("cargo", f'global-min-publish-age = "{days} days"', cargo_val or "MISSING",
         "effective" if cargo_ok else f"PRE-STAGED (cargo {cargo_num or '?'} < 1.100)")
    )

    # deno: no global config file; inherits npm's min-release-age since 2.8
    rows.append(("deno", f"inherits npm ({days}d), 24h built-in", "-", "resolution"))

    # VS Code
    vsc_val = _grep(VSCODE_SETTINGS, r'"extensions\.autoUpdateDelay"\s*:\s*(\d+)')
    vsc_auto = _grep(VSCODE_SETTINGS, r'"extensions\.autoUpdate"\s*:\s*"?([^",\n]+)"?')
    vsc_auto = vsc_auto.strip().strip('"')
    rows.append(
        ("VS Code", f'"extensions.autoUpdateDelay": {int(hours)}', f"{vsc_val or 'MISSING'} (autoUpdate={vsc_auto or '?'})",
         "auto-updates only")
    )

    # Homebrew gate
    gate = "enabled" if os.path.exists(os.path.expanduser("~/.config/cooldown/cooldown.env")) else "not configured"
    core = float(getattr(args, "hours_core", None) or hours)
    rows.append(
        (
            "brew",
            f"gate: {hours:g}h casks/taps, {core:g}h core",
            gate,
            "script gate",
        )
    )

    print(f"Cooldown policy target: {hours:g}h\n")
    width = max(len(r[0]) for r in rows)
    for tool, want, have, note in rows:
        print(f"  {tool:<{width}}  want: {want:<38} have: {have:<28} {note}")
    print()
    print(f"Config: {COOLDOWN_ENV}")
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    hours = float(args.hours)
    if hours <= 0:
        print("ERROR: hours must be > 0", file=sys.stderr)
        return 1
    days = max(1, round(hours / 24))
    minutes = int(hours * 60)
    seconds = int(hours * 3600)
    written: list[str] = []

    os.makedirs(os.path.dirname(COOLDOWN_ENV), exist_ok=True)
    hours_core = float(args.hours_core) if args.hours_core is not None else hours
    _write_text(
        COOLDOWN_ENV,
        "# Update cooldown (minimum release age) for all package managers on this machine.\n"
        "# Consumed by update-my-mac.sh, which derives every per-tool value from COOLDOWN_HOURS.\n"
        "# COOLDOWN_HOURS applies to casks and third-party taps (vendor installers, no review).\n"
        "# COOLDOWN_HOURS_CORE applies to homebrew-core formulae (human-reviewed merges).\n"
        f"COOLDOWN_HOURS={hours:g}\n"
        f"COOLDOWN_HOURS_CORE={hours_core:g}\n",
    )
    written.append(COOLDOWN_ENV)

    _write_text(
        os.path.expanduser("~/.config/uv/uv.toml"),
        "# Supply-chain cooldown: only resolve versions uploaded longer ago than this.\n"
        "# Docs: https://docs.astral.sh/uv/reference/settings/#exclude-newer\n"
        f'exclude-newer = "{hours:g} hours"\n',
    )
    written.append("~/.config/uv/uv.toml")

    _write_text(
        os.path.expanduser("~/.bunfig.toml"),
        "# Supply-chain cooldown: minimum age in seconds before a version may be installed.\n"
        f"# {seconds} = {hours:g}h. Docs: https://bun.com/docs/runtime/bunfig\n"
        "[install]\n"
        f"minimumReleaseAge = {seconds}\n",
    )
    written.append("~/.bunfig.toml")

    cargo_path = os.path.expanduser("~/.cargo/config.toml")
    existing = _read(cargo_path)
    block = (
        "# Supply-chain cooldown. Requires Rust 1.100+ (global-min-publish-age, RFC 3923).\n"
        "[registry]\n"
        f'global-min-publish-age = "{days} days"\n'
    )
    if "[registry]" in existing:
        import re

        existing = re.sub(
            r"(?ms)^\[registry\].*?(?=^\[|\Z)",
            block,
            existing,
        )
        _write_text(cargo_path, existing)
    else:
        _write_text(cargo_path, existing.rstrip() + "\n\n" + block)
    written.append("~/.cargo/config.toml")

    npm_bin = _npm_binary()
    if npm_bin:
        rc, _, err = run([npm_bin, "config", "set", "--location=user", "min-release-age", str(days)])
        written.append(f"~/.npmrc (min-release-age={days}, rc={rc}{': ' + err.strip() if err.strip() else ''})")

    rc, _, err = run(["pnpm", "config", "set", "-g", "minimumReleaseAge", str(minutes)])
    written.append(f"pnpm global config (minimumReleaseAge={minutes}, rc={rc}{': ' + err.strip() if err.strip() else ''})")

    if os.path.exists(VSCODE_SETTINGS):
        import re

        text = _read(VSCODE_SETTINGS)
        if re.search(r'"extensions\.autoUpdateDelay"\s*:', text):
            text = re.sub(
                r'"extensions\.autoUpdateDelay"\s*:\s*\d+',
                f'"extensions.autoUpdateDelay": {int(hours)}',
                text,
            )
        else:
            text = text.rstrip()
            assert text.endswith("}")
            text = text[:-1].rstrip()
            if not text.endswith("{"):
                text += ","
            text += f'\n    "extensions.autoUpdateDelay": {int(hours)}\n}}\n'
        _write_text(VSCODE_SETTINGS, text)
        written.append("VS Code settings.json")

    print(f"Cooldown synced to {hours:g}h:")
    for path in written:
        print(f"  {path}")
    print("\nOpen a new shell (or the tools re-read their config per invocation).")
    return 0


# ---------------------------------------------------------------------- small i/o


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError:
        return ""


def _write_text(path: str, text: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def _grep(path: str, pattern: str) -> str:
    import re

    match = re.search(pattern, _read(path), re.MULTILINE)
    return match.group(1).strip() if match else ""


def _npm_binary() -> str:
    for candidate in ("/opt/homebrew/bin/npm", shutil.which("npm") or ""):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    return ""


def _version_ge(have: str, need: str) -> bool:
    def parts(v: str) -> list[int]:
        out: list[int] = []
        for chunk in v.split("."):
            digits = "".join(c for c in chunk if c.isdigit())
            if digits == "":
                break
            out.append(int(digits))
        return out

    a, b = parts(have or ""), parts(need)
    if not a:
        return False
    while len(a) < len(b):
        a.append(0)
    return a[: len(b)] >= b


# --------------------------------------------------------------------------- main


def cmd_selftest(_args: argparse.Namespace) -> int:
    """Exercise the classification rules without touching the machine."""
    failures = 0

    def check(label: str, condition: bool) -> None:
        nonlocal failures
        print(f"  {'ok  ' if condition else 'FAIL'} {label}")
        failures += 0 if condition else 1

    # dependency rule, transitive: a -> b -> c(held)
    items = [
        {"kind": "formula", "name": "a", "status": "eligible", "reason": "", "deps": ["b"], "age_hours": 100},
        {"kind": "formula", "name": "b", "status": "eligible", "reason": "", "deps": ["c"], "age_hours": 100},
        {"kind": "formula", "name": "c", "status": "held", "reason": "", "deps": [], "age_hours": 1},
    ]
    apply_dependency_rule(items)
    check("direct dependency demotes parent", items[1]["status"] == "held")
    check("transitive dependency demotes grandparent", items[0]["status"] == "held")
    check("reason names the blocker", "c" in (items[1]["reason"] + items[0]["reason"]))

    # bypass must survive the dependency rule
    items = [
        {"kind": "formula", "name": "a", "status": "bypass", "reason": "explicit bypass", "deps": ["c"], "age_hours": 100},
        {"kind": "formula", "name": "c", "status": "held", "reason": "", "deps": [], "age_hours": 1},
    ]
    apply_dependency_rule(items)
    check("explicit bypass is not demoted", items[0]["status"] == "bypass")

    # timestamps
    check("parses Z timestamps", parse_iso("2026-10-21T10:44:22Z") is not None)
    check("parses offset timestamps", parse_iso("2026-10-21T10:44:22+02:00") is not None)
    check("rejects garbage", parse_iso("not-a-date") is None)

    # stdout/stderr must stay separate: brew warnings glued onto JSON break parsing
    rc, out, err = run(
        [
            sys.executable,
            "-c",
            "import sys;print('{\"a\":1}');print('Warning: deprecation', file=sys.stderr)",
        ]
    )
    check(
        "stdout/stderr kept separate",
        rc == 0 and out.strip() == '{"a":1}' and "deprecation" in err,
    )

    # tiered windows: core formulae reviewed by maintainers, casks/taps not
    check(
        "core formula uses the shorter window",
        threshold_for({"kind": "formula", "tap": "homebrew/core"}, 72, 24) == 24,
    )
    check(
        "cask keeps the full window",
        threshold_for({"kind": "cask", "tap": "homebrew/cask"}, 72, 24) == 72,
    )
    check(
        "third-party tap formula keeps the full window",
        threshold_for({"kind": "formula", "tap": "oven-sh/bun"}, 72, 24) == 72,
    )

    # version comparison
    check("11.21.0 >= 11.10.0", _version_ge("11.21.0", "11.10.0"))
    check("10.9.8 < 11.10.0", not _version_ge("10.9.8", "11.10.0"))
    check("1.99.0 < 1.100.0", not _version_ge("1.99.0", "1.100.0"))
    check("1.100.0 >= 1.100.0", _version_ge("1.100.0", "1.100.0"))

    # sudo classifier: artifact shapes as `brew info --json=v2` emits them
    app_only = ["Ghostty.app", {"uninstall": [{"quit": "com.mitchellh.ghostty"}]}]
    pkg_cask = [{"pkg": "NAPS2.pkg"}, {"uninstall": [{"pkgutil": "com.naps2.pkg"}]}]
    launchctl_cask = [
        "Visual Studio Code.app",
        {"uninstall": [{"launchctl": "com.microsoft.VSCode.ShipIt"}, {"quit": "com.microsoft.VSCode"}]},
    ]
    check("app-only cask is sudo-free", sudo_reasons("cask", app_only) == [])
    check("pkg cask needs sudo", "pkg installer" in sudo_reasons("cask", pkg_cask))
    check("pkgutil uninstall needs sudo", "uninstall pkgutil" in sudo_reasons("cask", pkg_cask))
    check(
        "launchctl uninstall needs sudo (brew probes via sudo)",
        sudo_reasons("cask", launchctl_cask) == ["uninstall launchctl"],
    )
    check("kext uninstall needs sudo", sudo_reasons("cask", [{"uninstall": [{"kext": "x.kext"}]}]) != [])
    check("delete uninstall needs sudo", sudo_reasons("cask", [{"uninstall": [{"delete": "/Library/x"}]}]) != [])
    check("formula never needs sudo", sudo_reasons("formula", pkg_cask) == [])
    check("missing cask artifacts fail closed", sudo_reasons("cask", None) != [])
    check("empty artifact list is sudo-free", sudo_reasons("cask", []) == [])

    # classification precedence: bypass > unknown date > age window > sudo
    old = 1000.0  # age in hours, well past any window
    check(
        "age-eligible sudo cask is deferred",
        plan_status("x", "cask", 1.0, old, 72, set(), pkg_cask)[0] == "sudo",
    )
    check(
        "age-eligible app cask stays eligible",
        plan_status("x", "cask", 1.0, old, 72, set(), app_only)[0] == "eligible",
    )
    check(
        "young sudo cask is held by age, not sudo",
        plan_status("x", "cask", 1.0, 1.0, 72, set(), pkg_cask)[0] == "held",
    )
    check(
        "unknown date wins over sudo",
        plan_status("x", "cask", None, None, 72, set(), pkg_cask)[0] == "unknown",
    )
    bypass_status, bypass_reason = plan_status("x", "cask", 1.0, old, 72, {"x"}, pkg_cask)
    check("bypass overrides age but not sudo deferral", bypass_status == "sudo")
    check("bypassed sudo reason keeps the bypass note", "explicit bypass" in bypass_reason)
    check(
        "bypassed sudo-free cask upgrades now",
        plan_status("x", "cask", 1.0, 1.0, 72, {"x"}, app_only)[0] == "bypass",
    )

    print(f"\n{'all checks passed' if failures == 0 else f'{failures} check(s) failed'}")
    return 0 if failures == 0 else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan", help="classify pending Homebrew upgrades")
    p_plan.add_argument("--hours", type=float, default=72)
    p_plan.add_argument(
        "--hours-core",
        type=float,
        default=None,
        help="shorter window for homebrew-core formulae (defaults to --hours)",
    )
    p_plan.add_argument("--bypass", default="", help="comma-separated package names")
    p_plan.add_argument("--json-out", default="")
    p_plan.add_argument("--eligible-out", default="")
    p_plan.add_argument(
        "--sudo-out",
        default="",
        help="write the names of age-eligible but sudo-requiring packages here",
    )
    p_plan.add_argument("--no-cache", action="store_true")
    p_plan.set_defaults(func=cmd_plan)

    p_status = sub.add_parser("status", help="show configured cooldowns")
    p_status.add_argument("--hours", type=float, default=72)
    p_status.add_argument("--hours-core", type=float, default=None)
    p_status.set_defaults(func=cmd_status)

    p_sync = sub.add_parser("sync", help="derive all per-tool configs from one threshold")
    p_sync.add_argument("--hours", type=float, default=72)
    p_sync.add_argument("--hours-core", type=float, default=None)
    p_sync.set_defaults(func=cmd_sync)

    p_test = sub.add_parser("selftest", help="exercise classification rules offline")
    p_test.set_defaults(func=cmd_selftest)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
