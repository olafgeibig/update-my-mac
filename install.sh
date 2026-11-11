#!/bin/bash
# filepath: /install.sh
# Description: One-line installer for update-my-mac
# Date: October 23, 2026
# Author: GEO5BE4
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/olafgeibig/update-my-mac/main/install.sh | bash
#
# Pinned version:
#   curl -fsSL .../install.sh | bash -s -- --ref v2026.11.11
#
# Overrides (environment):
#   UPDATE_MY_MAC_REF       latest (default) or a release tag such as v2026.11.11
#   UPDATE_MY_MAC_PREFIX    install prefix, default /usr/local
#   UPDATE_MY_MAC_TARBALL   install from a local .tar.gz instead of GitHub
#
# The script installs a tree (script + lib/cooldown.py) and a symlink, not a
# single file - see update-my-mac.sh --install.

set -euo pipefail

REPO="${UPDATE_MY_MAC_REPO:-olafgeibig/update-my-mac}"
PREFIX="${UPDATE_MY_MAC_PREFIX:-/usr/local}"
REF="${UPDATE_MY_MAC_REF:-latest}"
LOCAL_TARBALL="${UPDATE_MY_MAC_TARBALL:-}"
BASE_URL="${UPDATE_MY_MAC_BASE_URL:-https://github.com/$REPO/releases}"

say() { printf '%s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

# --- arguments -------------------------------------------------------------
while (( $# > 0 )); do
    case "$1" in
        --ref)    REF="${2:-}"; shift 2 ;;
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --ref=*)  REF="${1#*=}"; shift ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        -h|--help)
            sed -n '7,19p' "$0" 2>/dev/null || say "one-line installer for update-my-mac"
            exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

# --- preflight -------------------------------------------------------------
[[ "$(uname -s)" == "Darwin" ]] || die "update-my-mac is macOS only (found $(uname -s))"
for bin in curl tar shasum mktemp; do
    command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
done
command -v python3 >/dev/null 2>&1 \
    || warn "python3 not found - the Homebrew cooldown gate needs it (install the Xcode command line tools)"

cleanup_dir=""
cleanup() { [[ -n "$cleanup_dir" ]] && rm -rf "$cleanup_dir"; return 0; }
trap cleanup EXIT

# TLS is required unless BASE_URL is an explicit local test server. No arrays
# here: bash 3.2 (macOS) treats "${empty[@]}" as unbound under set -u.
fetch() {
    case "$BASE_URL" in
        http://127.0.0.1:*|http://localhost:*) curl "$@" ;;
        *) curl --proto '=https' --tlsv1.2 "$@" ;;
    esac
}

# --- fetch the release tarball --------------------------------------------
if [[ -n "$LOCAL_TARBALL" ]]; then
    TGZ="$LOCAL_TARBALL"
    [[ -f "$TGZ" ]] || die "tarball not found: $TGZ"
    say "📦 Using local tarball: $TGZ"
else
    if [[ "$REF" == "latest" ]]; then
        URL="$BASE_URL/latest/download/update-my-mac.tar.gz"
    else
        URL="$BASE_URL/download/$REF/update-my-mac-$REF.tar.gz"
    fi
    cleanup_dir="$(mktemp -d)"
    TGZ="$cleanup_dir/update-my-mac.tar.gz"
    say "📦 Downloading $URL"
    fetch -fsSL -o "$TGZ" "$URL" \
        || die "download failed. No release tarball for '$REF'? See https://github.com/$REPO/releases"

    # Checksum is mandatory for a normal download: this tool exists to slow down
    # supply-chain attacks, so it should not install unverified bytes itself.
    if fetch -fsSL -o "$cleanup_dir/checksum" "$URL.sha256"; then
        expected="$(awk '{print $1}' "$cleanup_dir/checksum")"
        actual="$(shasum -a 256 "$TGZ" | awk '{print $1}')"
        if [[ "$expected" != "$actual" ]]; then
            die "checksum mismatch: expected $expected, got $actual"
        fi
        say "✅ sha256 verified"
    else
        die "checksum file missing ($URL.sha256) - refusing to install unverified bytes"
    fi
fi

# --- extract ---------------------------------------------------------------
[[ -n "$cleanup_dir" ]] || cleanup_dir="$(mktemp -d)"
EXTRACT="$cleanup_dir/extract"
mkdir -p "$EXTRACT"
tar -xzf "$TGZ" -C "$EXTRACT" || die "cannot extract $TGZ"

root_name="$(tar -tzf "$TGZ" | head -1 | cut -d/ -f1)"
SRC="$EXTRACT/$root_name"
[[ -x "$SRC/update-my-mac.sh" || -f "$SRC/update-my-mac.sh" ]] \
    || die "unexpected tarball layout: no update-my-mac.sh in $root_name"
[[ -f "$SRC/lib/cooldown.py" ]] \
    || die "tarball lacks lib/cooldown.py - it cannot install a working tree"

chmod +x "$SRC/update-my-mac.sh"

# --- install ---------------------------------------------------------------
export UPDATE_MY_MAC_PREFIX="$PREFIX"
say "🔧 Installing into $PREFIX (sudo may ask for your password)"
"$SRC/update-my-mac.sh" --install

say ""
say "Done. Next:"
say "  update-my-mac --version     # version, install path, cooldown helper state"
say "  update-my-mac --report      # what would update, what is held back, and why"
