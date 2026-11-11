#!/bin/zsh
# filepath: /Users/GEO5BE4/bin/update.sh
# Description: Script to update various software on macOS
# Date: June 6, 2025
# Author: GEO5BE4
VERSION="v2026.10.22"

# Color definitions for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Cooldown policy (minimum release age)
#
# A compromised release is usually detected and pulled within hours. Every
# update path in this script therefore refuses versions younger than
# COOLDOWN_HOURS. Most package managers enforce this themselves via their own
# global config (uv, npm, pnpm, bun, deno, cargo); Homebrew has no such setting,
# so lib/cooldown.py gates brew upgrades on the merge date of the formula/cask.
#
# Homebrew is tiered: casks and third-party taps wait the full window (vendor
# installers run as root, taps are unreviewed), homebrew-core formulae only
# COOLDOWN_HOURS_CORE (a maintainer reviews every merge, bottles are built by
# Homebrew CI and downloads are checksummed).
#
# Change the threshold in one place only: ~/.config/cooldown/cooldown.env
# Then run: update-my-mac --cooldown-sync
# ---------------------------------------------------------------------------
COOLDOWN_CONFIG="${COOLDOWN_CONFIG:-$HOME/.config/cooldown/cooldown.env}"
if [[ -r "$COOLDOWN_CONFIG" ]]; then
    source "$COOLDOWN_CONFIG"
fi
COOLDOWN_HOURS="${COOLDOWN_HOURS:-72}"
COOLDOWN_HOURS_CORE="${COOLDOWN_HOURS_CORE:-$COOLDOWN_HOURS}"
COOLDOWN_ENFORCE="${COOLDOWN_ENFORCE:-1}"
COOLDOWN_BYPASS="${COOLDOWN_BYPASS:-}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_PLUGIN_WIPE="${FORCE_PLUGIN_WIPE:-0}"

# Where this script lives and where its helper lives. ${0:A} resolves symlinks,
# so an install via /usr/local/bin/update-my-mac -> libexec/... still finds
# lib/cooldown.py next to the real script. UPDATE_MY_MAC_HELPER overrides.
# zsh sets $0 to the function name inside functions, so capture the invocation
# path once here and use $SELF everywhere else.
SELF="$0"
SCRIPT_DIR="${0:A:h}"
COOLDOWN_HELPER="${UPDATE_MY_MAC_HELPER:-$SCRIPT_DIR/lib/cooldown.py}"

# ---------------------------------------------------------------------------
# Installation layout
#
# This script is NOT self-contained: the Homebrew cooldown gate needs
# lib/cooldown.py next to it. A flat copy to /usr/local/bin therefore installs a
# half-broken tool (fail-closed: no brew upgrades, --cooldown-sync dead). The
# installer deploys the whole tree and symlinks the entry point:
#
#   /usr/local/libexec/update-my-mac/update-my-mac.sh
#   /usr/local/libexec/update-my-mac/lib/cooldown.py
#   /usr/local/bin/update-my-mac -> ../libexec/update-my-mac/update-my-mac.sh
#
# Override the prefix with UPDATE_MY_MAC_PREFIX (e.g. for a $HOME-only install).
# ---------------------------------------------------------------------------
INSTALL_PREFIX="${UPDATE_MY_MAC_PREFIX:-/usr/local}"
INSTALL_LIBDIR="$INSTALL_PREFIX/libexec/update-my-mac"
INSTALL_BIN="$INSTALL_PREFIX/bin/update-my-mac"
INSTALL_LINK_TARGET="../libexec/update-my-mac/update-my-mac.sh"

# Logging setup
LOG_DIR="$HOME/Library/Logs/update-my-mac"
LOG_FILE="$LOG_DIR/update-$(date +%Y%m%d_%H%M%S).log"
ANALYSIS_PROMPT="Analyze this system update log and provide:
1. Any errors, failures, or warning messages that need attention
2. Summary of what was successfully updated 
3. Specific manual actions the user needs to take (like Xcode updates requiring App Store)
4. Any recommendations for follow-up maintenance

Keep responses concise and actionable."

# Initialize logging
init_logging() {
    # Create log directory if it doesn't exist
    mkdir -p "$LOG_DIR" 2>/dev/null || {
        echo "Warning: Could not create log directory $LOG_DIR"
        LOG_FILE=""
        return 1
    }
    
    # Initialize log file with header
    cat << EOF > "$LOG_FILE"
=== update-my-mac.sh Log ===
Date: $(date)
User: $(whoami)
Script: update-my-mac.sh
Arguments: $@
========================================

EOF
    echo "📝 Logging enabled: $LOG_FILE"
}

# Function to strip color codes for logging
strip_colors() {
    sed -r "s/\x1b\[[0-9;]*m//g"
}

# Function to log messages
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local clean_message=$(echo "$message" | strip_colors)
    
    # Write to log file if available
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $clean_message" >> "$LOG_FILE"
    fi
}

# Function to print section headers
print_header() {
    echo -e "\n${BLUE}==== $1 ====${NC}\n"
    log_message "INFO" "==== $1 ===="
}

# Function to print success messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
    log_message "SUCCESS" "✓ $1"
}

# Function to print error messages
print_error() {
    echo -e "${RED}✗ $1${NC}"
    log_message "ERROR" "✗ $1"
}

# Function to print warnings
print_warning() {
    echo -e "${YELLOW}! $1${NC}"
    log_message "WARNING" "! $1"
}

# Function to log and execute commands
log_command() {
    local cmd="$1"
    local description="$2"
    
    if [ -n "$description" ]; then
        log_message "INFO" "$description"
    fi
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CMD]  $cmd" | tee -a "$LOG_FILE" 2>/dev/null
    
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DRY]  skipped (dry run)" | tee -a "$LOG_FILE" 2>/dev/null
        log_message "INFO" "[DRY RUN] $cmd"
        return 0
    fi

    local start_time=$SECONDS
    
    # Execute command and capture output
    eval "$cmd" 2>&1 | while IFS= read -r line; do
        if [ -n "$line" ]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OUT]  $line" | tee -a "$LOG_FILE" 2>/dev/null
        fi
    done
    
    local exit_code=${PIPESTATUS[0]}
    local duration=$((SECONDS - start_time))
    
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [EXIT] $cmd exited with code: ${exit_code:-0} (duration: ${duration}s)" | tee -a "$LOG_FILE" 2>/dev/null
    return ${exit_code:-0}
}

# Function to analyze log with LLM
analyze_log() {
    if command -v llm &> /dev/null; then
        echo -e "\n${BLUE}🤖 Analyzing log file with LLM...${NC}"
        log_message "INFO" "Starting LLM analysis"
        
        if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
            cat "$LOG_FILE" | llm "$ANALYSIS_PROMPT" 2>/dev/null || {
                print_error "LLM analysis failed"
                log_message "ERROR" "LLM analysis failed"
                return 1
            }
            log_message "INFO" "LLM analysis completed"
        else
            print_error "Log file not found for analysis"
            return 1
        fi
    else
        echo -e "\n${YELLOW}💡 Tip: Install 'llm' tool for automatic analysis: pip install llm${NC}"
        log_message "INFO" "LLM tool not available - analysis skipped"
    fi
}

# Function to show log file info
show_log_info() {
    if [ -n "$LOG_FILE" ] && [ -f "$LOG_FILE" ]; then
        local file_size=$(du -h "$LOG_FILE" | cut -f1)
        local line_count=$(wc -l < "$LOG_FILE")
        echo -e "\n${GREEN}📝 Log saved to: $LOG_FILE${NC}"
        echo "${BLUE}📊 Log size: $file_size, $line_count lines${NC}"
        echo "${BLUE}📖 View full log: less $LOG_FILE${NC}"
        log_message "INFO" "Log file completed - size: $file_size, lines: $line_count"
    fi
}

# Function to update Homebrew and its packages, gated by the cooldown policy
update_brew() {
    print_header "Updating Homebrew packages (cooldown ${COOLDOWN_HOURS}h)"
    
    # Check if brew is installed
    if ! command -v brew &> /dev/null; then
        print_error "Homebrew is not installed"
        return 1
    fi

    if [[ ! -f "$COOLDOWN_HELPER" ]]; then
        print_error "Cooldown helper not found at $COOLDOWN_HELPER - refusing to upgrade unfiltered"
        return 2
    fi

    if [[ "$COOLDOWN_ENFORCE" == "0" ]]; then
        print_warning "COOLDOWN DISABLED for this run - installing whatever upstream currently offers"
        log_message "WARNING" "cooldown explicitly disabled (--no-cooldown)"
    fi

    # Update metadata first: the gate needs current formula/cask definitions
    log_command "brew update" "Updating Homebrew..."

    local stamp=$(date +%Y%m%d_%H%M%S)
    local plan_json="$LOG_DIR/brew-cooldown-$stamp.json"
    local eligible_txt="$LOG_DIR/brew-eligible-$stamp.txt"
    local -a bypass_args
    if [[ -n "$COOLDOWN_BYPASS" ]]; then
        bypass_args=(--bypass "$COOLDOWN_BYPASS")
    else
        bypass_args=()
    fi

    print_header "Evaluating cooldown gate"
    python3 "$COOLDOWN_HELPER" plan \
        --hours "$COOLDOWN_HOURS" \
        --hours-core "$COOLDOWN_HOURS_CORE" \
        "${bypass_args[@]}" \
        --json-out "$plan_json" \
        --eligible-out "$eligible_txt"
    local gate_rc=$?

    # fail closed: if the gate cannot be evaluated, upgrade nothing
    if (( gate_rc == 2 )); then
        print_error "Cooldown gate could not evaluate Homebrew state - no packages upgraded"
        return 2
    elif (( gate_rc == 3 )); then
        print_warning "Some release dates are unknown - those packages were held back"
    fi

    local -a eligible
    eligible=("${(@f)$(<"$eligible_txt")}")
    eligible=(${eligible:#})

    if (( ${#eligible} == 0 )); then
        print_warning "Nothing past the ${COOLDOWN_HOURS}h cooldown window - Homebrew left untouched"
    else
        log_command "brew upgrade ${(j: :)eligible}" "Upgrading ${#eligible} package(s) older than ${COOLDOWN_HOURS}h..."
    fi

    # Keep a 30-day rollback window instead of deleting every previous version
    log_command "HOMEBREW_CLEANUP_MAX_AGE_DAYS=30 brew cleanup" "Cleaning up old versions older than 30 days..."

    print_success "Homebrew update completed (gate: $plan_json)"
}

# Resolve the npm binary that actually honours min-release-age.
# ~/.brv-cli/bin used to shadow /opt/homebrew with a bundled npm 10.9.8, whose
# global prefix pointed at an empty directory - updates went nowhere and the
# cooldown key was silently ignored.
resolve_npm() {
    if [[ -x /opt/homebrew/bin/npm ]]; then
        echo "/opt/homebrew/bin/npm"
    elif command -v npm &> /dev/null; then
        command -v npm
    fi
}

# True when $1 >= $2 (version strings)
version_ge() {
    local have="$1" need="$2"
    [[ -n "$have" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)" == "$need" ]]
}

# Function to update npm global packages
update_npm() {
    print_header "Updating npm global packages (cooldown ${COOLDOWN_HOURS}h)"
    
    # Check if npm is installed
    local npm_bin
    npm_bin="$(resolve_npm)"
    if [[ -z "$npm_bin" ]]; then
        print_error "npm is not installed"
        return 1
    fi

    local npm_version="$("$npm_bin" --version 2>/dev/null)"
    if ! version_ge "$npm_version" "11.10.0"; then
        print_warning "npm $npm_version ignores min-release-age (needs >= 11.10.0)"
        print_warning "Skipping global npm updates rather than installing unvetted versions"
        print_warning "Fix: put /opt/homebrew/bin ahead of bundled node installations in PATH"
        return 1
    fi

    if [[ -n "${NPM_BYPASS:-}" ]]; then
        local -a bypass_pkgs
        local -a pkgs
        local pkg
        IFS=, read -rA bypass_pkgs <<< "$NPM_BYPASS"
        for pkg in "${bypass_pkgs[@]}"; do
            pkgs+=("${pkg}@latest")
        done
        print_warning "--bypass ${NPM_BYPASS}: installing exactly these npm globals at @latest with --min-release-age=0 (one-off, not persisted)"
        log_command "$npm_bin install -g ${pkgs[*]} --min-release-age=0" "Installing ONLY ${bypass_pkgs[*]}@latest (explicit bypass)..."
    elif [[ "$COOLDOWN_ENFORCE" == "0" ]]; then
        log_command "$npm_bin update -g --min-release-age=0" "Updating global npm packages (cooldown DISABLED)..."
    else
        log_command "$npm_bin update -g" "Updating global npm packages (min-release-age=3d)..."
    fi
    
    print_success "npm update completed"
}

# Function to update bun package manager
update_bun() {
    print_header "Updating Bun global packages (cooldown ${COOLDOWN_HOURS}h)"
    
    # Check if bun is installed
    if ! command -v bun &> /dev/null; then
        print_error "Bun is not installed"
        return 1
    fi

    # The bun binary itself comes from Homebrew and is therefore governed by the
    # brew gate; `bun upgrade` would bypass it and fight the package manager.
    if brew list --formula bun &> /dev/null; then
        print_warning "Bun itself is managed by Homebrew - handled by the brew gate, not 'bun upgrade'"
    fi

    # --bypass cannot be honored for bun: minimumReleaseAge applies during
    # resolution, so even an exact-version `bun add -g <pkg>@<version>` is the
    # only way (documented in --help). Warn instead of silently ignoring.
    if [[ -n "${BUN_BYPASS:-}" ]]; then
        print_warning "--bypass does not apply to bun (minimumReleaseAge applies during resolution) - use 'bun add -g <pkg>@<version>' for an exact-version override"
    fi
    
    log_command "bun update -g" "Updating global Bun packages (minimumReleaseAge=72h)..."
    
    print_success "Bun update completed"
}

# Function to inspect AI development plugins.
# Wiping a plugin cache forces an immediate re-resolve of every plugin, which is
# the opposite of a cooldown - so it only happens on explicit request.
update_plugins() {
    print_header "AI development plugin state"

    local opencode_pkg="$HOME/.config/opencode/package.json"
    if [[ -f "$opencode_pkg" ]]; then
        local pinned=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(', '.join(f'{k}@{v}' for k,v in d.get('dependencies',{}).items()))" "$opencode_pkg" 2>/dev/null)
        print_success "opencode plugin pins: ${pinned:-none}"
    else
        print_warning "No opencode plugin manifest at $opencode_pkg"
    fi

    local claude_plugins="$HOME/.claude/plugins/installed_plugins.json"
    if [[ -f "$claude_plugins" ]]; then
        local claude_list=$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
for name, entries in d.get('plugins',{}).items():
    for e in entries:
        print(f\"{name} {e.get('version','?')} {str(e.get('gitCommitSha',''))[:8]}\")
" "$claude_plugins" 2>/dev/null)
        print_success "Claude Code plugins (version-pinned): ${claude_list:-none}"
    fi

    if [[ "$FORCE_PLUGIN_WIPE" == "1" ]]; then
        print_warning "Force wipe requested - clearing plugin caches, next start re-resolves immediately"
        local opencode_cache="$HOME/.cache/opencode/node_modules"
        if [ -d "$opencode_cache" ]; then
            log_command "rm -rf \"$opencode_cache\"" "Clearing OpenCode plugin cache..."
        fi
        local claude_cache="$HOME/.claude/plugins/cache"
        if [ -d "$claude_cache" ]; then
            log_command "rm -rf \"$claude_cache\"/*" "Clearing Claude Code plugin cache..."
        fi
        print_success "Plugin caches cleared"
    else
        print_warning "No cache wipe: it would bypass the ${COOLDOWN_HOURS}h cooldown. Use --plugins-force to override."
    fi
}

# Function to update uv global packages
update_uv() {
    print_header "Updating uv global packages (cooldown ${COOLDOWN_HOURS}h)"
    
    # Check if uv is installed
    if ! command -v uv &> /dev/null; then
        print_error "uv is not installed"
        return 1
    fi

    # The cooldown is configured globally in ~/.config/uv/uv.toml (exclude-newer).
    # Without it, `uv tool upgrade --all` resolves the newest release immediately.
    # An explicit --bypass (via UV_BYPASS) overrides the gate for exactly the named
    # tools; the config-file guard still matters for the normal path.
    if [[ ! -f "$HOME/.config/uv/uv.toml" && -z "${UV_BYPASS:-}" ]]; then
        print_error "~/.config/uv/uv.toml is missing - refusing to upgrade tools without a cooldown"
        print_warning "Fix with: $SCRIPT_DIR/update-my-mac.sh --cooldown-sync"
        return 2
    fi

    local log_start_line=0
    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
        log_start_line=$(wc -l < "$LOG_FILE")
    fi
    local exit_code=0

    if [[ -n "${UV_BYPASS:-}" ]]; then
        local -a bypass_pkgs
        IFS=, read -rA bypass_pkgs <<< "$UV_BYPASS"
        print_warning "--bypass ${UV_BYPASS}: upgrading exactly these uv tools with UV_EXCLUDE_NEWER=false (one-off, not persisted)"
        log_command "UV_EXCLUDE_NEWER=false uv tool upgrade ${bypass_pkgs[*]}" "Updating ONLY ${bypass_pkgs[*]} (explicit bypass)..." || exit_code=$?
    elif [[ "$COOLDOWN_ENFORCE" == "0" ]]; then
        log_command "UV_EXCLUDE_NEWER=false uv tool upgrade --all" "Updating global packages managed by uv (cooldown DISABLED)..." || exit_code=$?
    else
        log_command "uv tool upgrade --all" "Updating global packages managed by uv (exclude-newer)..." || exit_code=$?
    fi

    if (( exit_code != 0 )); then
        print_error "uv tool upgrade --all exited with code $exit_code"
        return "$exit_code"
    fi

    if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] && \
        tail -n "+$((log_start_line + 1))" "$LOG_FILE" | grep -Fq '[OUT]  error: Failed to upgrade '; then
        print_error "uv reported one or more tool-upgrade failures; see $LOG_FILE"
        return 1
    fi

    print_success "uv update completed"
}

# Function to update macOS App Store apps
update_appstore() {
    print_header "Updating App Store applications"
    
    # Check if mas-cli is installed (Mac App Store command line interface)
    if ! command -v mas &> /dev/null; then
        print_warning "mas-cli is not installed. Cannot update App Store apps from the command line."
        print_warning "To install mas: brew install mas"
        return 1
    else
        log_command "mas upgrade" "Updating App Store applications..."
        print_success "App Store updates completed"
    fi
}

# Function to update Xcode
update_xcode() {
    print_header "Updating Xcode"
    
    # Check if xcode-select is installed
    if ! command -v xcode-select &> /dev/null; then
        print_error "Xcode command line tools are not installed"
        return 1
    fi
    
    log_command "softwareupdate --list | grep \"Command Line Tools\"" "Checking for Xcode updates..."
    
    # For Xcode command line tools
    if softwareupdate --list | grep -q "Command Line Tools"; then
        log_command "softwareupdate --install --all --agree-to-license" "Updating Xcode command line tools..."
    fi
    
    # For full Xcode, we can check if it's installed first
    if [ -d "/Applications/Xcode.app" ]; then
        print_warning "Full Xcode is installed."
        print_warning "Please update Xcode manually through the App Store."
        # mas can be used to update Xcode if mas-cli is installed
        if command -v mas &> /dev/null; then
            XCODE_ID=$(mas list | grep Xcode | awk '{print $1}')
            if [ ! -z "$XCODE_ID" ]; then
                log_command "mas upgrade $XCODE_ID" "Attempting to update Xcode via mas-cli..."
            fi
        fi
    fi
    
    print_success "Xcode update check completed"
}

# Function to update system software
update_system() {
    print_header "Checking for macOS updates"
    
    log_command "softwareupdate --list" "Checking for system updates..."
    
    print_warning "To install system updates, run: softwareupdate --install --all --agree-to-license"
    print_warning "Note: System updates may require a restart"
}

# Function to run quick updates only (fast updates, ~1-2 minutes)
update_quick() {
    update_brew
    update_npm
    update_bun
    update_uv
    update_plugins
    
    # Show log information and run analysis
    show_log_info
    analyze_log
}

# Function to run all updates
update_all() {
    update_brew
    update_npm
    update_bun
    update_uv
    update_plugins
    update_appstore
    update_xcode
    update_system
    
    # Show log information and run analysis
    show_log_info
    analyze_log
}

cleanup() {
    print_header "Cleaning up temporary files"
    log_command "npm cache clean --force" "Cleaning npm cache..."
    log_command "uv cache prune" "Cleaning uv cache..."
    # Keep previous versions around: they are the rollback target if a fresh
    # release turns out to be broken or malicious after the cooldown window.
    log_command "HOMEBREW_CLEANUP_MAX_AGE_DAYS=30 brew cleanup" "Cleaning brew versions older than 30 days..."
    print_success "Cleanup completed"
}

# Show the effective cooldown configuration of every package manager
cooldown_status() {
    print_header "Cooldown status (target: ${COOLDOWN_HOURS}h)"
    if [[ ! -f "$COOLDOWN_HELPER" ]]; then
        print_error "Cooldown helper not found at $COOLDOWN_HELPER"
        return 1
    fi
    python3 "$COOLDOWN_HELPER" status --hours "$COOLDOWN_HOURS" --hours-core "$COOLDOWN_HOURS_CORE"
}

# Derive every per-tool setting from COOLDOWN_HOURS (single knob)
cooldown_sync() {
    print_header "Syncing cooldown configuration to ${COOLDOWN_HOURS}h"
    if [[ ! -f "$COOLDOWN_HELPER" ]]; then
        print_error "Cooldown helper not found at $COOLDOWN_HELPER"
        return 1
    fi
    if ! python3 "$COOLDOWN_HELPER" sync --hours "$COOLDOWN_HOURS" --hours-core "$COOLDOWN_HOURS_CORE"; then
        print_error "Cooldown sync failed"
        return 1
    fi
    print_success "Cooldown configuration synced"
}

# Report only: what would be upgraded, what is held, and why
cooldown_report() {
    print_header "Cooldown report (${COOLDOWN_HOURS}h) - no changes"
    if [[ ! -f "$COOLDOWN_HELPER" ]]; then
        print_error "Cooldown helper not found at $COOLDOWN_HELPER"
        return 1
    fi
    local -a bypass_args
    if [[ -n "$COOLDOWN_BYPASS" ]]; then
        bypass_args=(--bypass "$COOLDOWN_BYPASS")
    else
        bypass_args=()
    fi
    python3 "$COOLDOWN_HELPER" plan --hours "$COOLDOWN_HOURS" --hours-core "$COOLDOWN_HOURS_CORE" "${bypass_args[@]}" --no-cache
    local rc=$?
    (( rc == 2 )) && print_error "Gate could not be evaluated"
    (( rc == 3 )) && print_warning "Some release dates could not be established (held)"
    cooldown_status
    return 0
}

# Run a command with sudo only when the install prefix is not writable by us
install_priv() {
    local probe="$INSTALL_PREFIX"
    while [[ ! -e "$probe" && "$probe" != "/" ]]; do
        probe="${probe:h}"
    done
    if [[ -w "$probe" ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Report where we run from and whether the cooldown helper is actually there
show_version() {
    echo "update-my-mac version $VERSION"
    echo "  invoked as:   $SELF"
    echo "  script dir:   $SCRIPT_DIR"
    if [[ -f "${COOLDOWN_HELPER:-}" ]]; then
        local state="enforced"
        [[ "$COOLDOWN_ENFORCE" == "0" ]] && state="disabled"
        echo "  cooldown:     ${COOLDOWN_HOURS}h ${state}"
        echo "  helper:       $COOLDOWN_HELPER (ok)"
    else
        echo "  cooldown:     ${COOLDOWN_HOURS}h"
        echo "  helper:       MISSING at ${COOLDOWN_HELPER:-<unset>}"
        echo "                Homebrew upgrades are refused while the helper is missing."
        echo "                Fix: ./update-my-mac.sh --install (from the repo checkout)"
    fi
    if [[ -r "$COOLDOWN_CONFIG" ]]; then
        echo "  config:       $COOLDOWN_CONFIG"
    else
        echo "  config:       $COOLDOWN_CONFIG (absent, built-in defaults in use)"
    fi
    if [[ -L "$INSTALL_BIN" ]]; then
        echo "  install:      $INSTALL_BIN -> $(readlink "$INSTALL_BIN")"
    elif [[ -f "$INSTALL_BIN" ]]; then
        echo "  install:      $INSTALL_BIN (flat file - old layout, missing lib/)"
    else
        echo "  install:      not installed in $INSTALL_PREFIX (running from a checkout)"
    fi
}

# Function to install the script tree (script + lib) and link it into $PREFIX/bin
install_script() {
    print_header "Installing update-my-mac $VERSION to $INSTALL_PREFIX"

    local source_script="$SCRIPT_DIR/update-my-mac.sh"
    local source_lib="$SCRIPT_DIR/lib/cooldown.py"

    if [[ ! -f "$source_script" ]]; then
        print_error "Source script not found at $source_script"
        return 1
    fi
    if [[ ! -f "$source_lib" ]]; then
        print_error "Cooldown helper not found at $source_lib"
        print_warning "Refusing to install an incomplete tree - without lib/cooldown.py the"
        print_warning "Homebrew gate cannot run and no brew package would ever be upgraded."
        print_warning "Run this from the repository checkout, not from an old flat install."
        return 1
    fi

    # Anything already in the way is moved aside - a regular file here is an old
    # flat install (v2026.01.x) that predates the helper.
    if [[ -e "$INSTALL_BIN" || -L "$INSTALL_BIN" ]]; then
        local backup="${INSTALL_BIN}.backup.$(date +%Y%m%d_%H%M%S)"
        print_warning "Existing $INSTALL_BIN - backing up to $(basename "$backup")"
        install_priv mv "$INSTALL_BIN" "$backup" || return 1
        # Keep the two newest backups only, do not let /usr/local/bin fill up
        local -a backups
        backups=("${INSTALL_BIN}".backup.*(N))
        if (( ${#backups} > 2 )); then
            local -a stale
            stale=(${(O)backups})
            install_priv rm -f "${stale[@]:2}"
            echo "Pruned $(( ${#backups} - 2 )) older backup(s)"
        fi
    fi

    echo "Deploying tree to $INSTALL_LIBDIR ..."
    install_priv mkdir -p "$INSTALL_LIBDIR/lib" || return 1
    # Compare resolved paths: installing from the installed copy itself must not
    # cp the file onto itself (cp exits 1 for "identical", which would abort).
    if [[ "${source_script:A}" != "${INSTALL_LIBDIR:A}/update-my-mac.sh" ]]; then
        install_priv cp "$source_script" "$INSTALL_LIBDIR/update-my-mac.sh" || return 1
    fi
    if [[ "${source_lib:A}" != "${INSTALL_LIBDIR:A}/lib/cooldown.py" ]]; then
        install_priv cp "$source_lib" "$INSTALL_LIBDIR/lib/cooldown.py" || return 1
    fi
    install_priv chmod 755 "$INSTALL_LIBDIR/update-my-mac.sh" || return 1
    install_priv chmod 644 "$INSTALL_LIBDIR/lib/cooldown.py" || return 1

    echo "Linking $INSTALL_BIN ..."
    install_priv mkdir -p "$INSTALL_PREFIX/bin" || return 1
    install_priv ln -sfn "$INSTALL_LINK_TARGET" "$INSTALL_BIN" || return 1

    # Verify by executing the installed entry point, not by trusting cp
    local installed
    installed=$("$INSTALL_BIN" --version 2>&1)
    if [[ "$installed" != *"version $VERSION"* ]]; then
        print_error "Verification failed - $INSTALL_BIN --version returned:"
        echo "$installed"
        return 1
    fi
    if [[ "$installed" != *"helper:"*"(ok)"* ]]; then
        print_error "Verification failed - the installed copy cannot find lib/cooldown.py:"
        echo "$installed"
        return 1
    fi

    print_success "Installed $VERSION"
    echo "  $INSTALL_BIN -> $INSTALL_LINK_TARGET"
    echo "  lib/cooldown.py deployed alongside the script"
    echo "Run: update-my-mac --version   (shows version, helper and install path)"
}

# Function to uninstall the script tree from $PREFIX
uninstall_script() {
    print_header "Uninstalling update-my-mac from $INSTALL_PREFIX"

    local removed=0
    if [[ -L "$INSTALL_BIN" || -f "$INSTALL_BIN" ]]; then
        install_priv rm -f "$INSTALL_BIN" || return 1
        removed=1
    fi
    if [[ -d "$INSTALL_LIBDIR" ]]; then
        install_priv rm -rf "$INSTALL_LIBDIR" || return 1
        removed=1
    fi
    # Remove the libexec container too, but only if it is empty (never rm -rf a
    # shared libexec directory that holds other tools)
    install_priv rmdir "$INSTALL_LIBDIR:h" 2>/dev/null

    if (( removed == 0 )); then
        print_error "Nothing installed under $INSTALL_PREFIX"
        return 1
    fi

    print_success "Removed $INSTALL_BIN and $INSTALL_LIBDIR"
    local -a backups
    backups=("${INSTALL_BIN}".backup.*(N))
    if (( ${#backups} > 0 )); then
        print_warning "Backups kept in ${INSTALL_BIN:h}:"
        printf '  %s\n' "${backups[@]:t}"
    fi
    echo "Logs and the cooldown cache are left in place:"
    echo "  $LOG_DIR"
    echo "  ~/.cache/update-my-mac"
}

# Show help message
show_help() {
    echo "Usage: update.sh [OPTIONS]"
    echo "Update various software on your macOS system."
    echo ""
    echo "Cooldown:"
    echo "  uv, npm, pnpm, bun, deno and cargo enforce a ${COOLDOWN_HOURS}h minimum age in their own"
    echo "  config. Homebrew has no such setting, so this script filters by merge date:"
    echo "  ${COOLDOWN_HOURS}h for casks and third-party taps, ${COOLDOWN_HOURS_CORE}h for human-reviewed"
    echo "  homebrew-core formulae."
    echo ""
    echo "Options:"
    echo "  --quick      Run quick updates only (brew, npm, bun, uv, plugins) - default"
    echo "  --full       Update everything (includes appstore, xcode, system)"
    echo "  --all        Update everything (alias for --full)"
    echo "  --brew       Update Homebrew and its packages (cooldown-gated)"
    echo "  --npm        Update npm and global npm packages"
    echo "  --bun        Update Bun and global Bun packages"
    echo "  --uv         Update uv and global uv packages"
    echo "  --plugins    Show AI plugin pins (no cache wipe - that would bypass the cooldown)"
    echo "  --appstore   Update App Store applications (requires mas-cli)"
    echo "  --xcode      Update Xcode and command line tools"
    echo "  --system     Check for macOS system updates"
    echo "  --cleanup    Clean up cached and temporary files"
    echo ""
    echo "Cooldown options:"
    echo "  --report          Show what would update, what is held and why (no changes)"
    echo "  --cooldown-status Show the effective cooldown setting per package manager"
    echo "  --cooldown-sync   Re-derive all per-tool configs from COOLDOWN_HOURS"
    echo "  --bypass PKG[,PKG] One-off exception, this run only (not persisted, logged):
                       with --brew: exempt the named packages from the gate
                       with --uv:   upgrade exactly these tools with UV_EXCLUDE_NEWER=false
                       with --npm:  install these globals at @latest with --min-release-age=0
                       with --bun:  ignored (use 'bun add -g <pkg>@<version>')"
    echo "  --no-cooldown     Emergency: disable the gate where this script can (brew, uv, npm)"
    echo "  --dry-run         Print the commands instead of executing them"
    echo "  --plugins-force   Allow wiping plugin caches (re-resolves immediately)"
    echo ""
    echo "Installation:"
    echo "  --install    Deploy $INSTALL_BIN"
    echo "               (tree in $INSTALL_LIBDIR, script + lib/cooldown.py)"
    echo "  --uninstall  Remove the installed tree (keeps logs and cooldown cache)"
    echo "  --version    Version, cooldown helper state and install path"
    echo "  --help       Display this help message"
    echo ""
    echo "Prefix override: UPDATE_MY_MAC_PREFIX (default /usr/local)"
    echo "Helper override: UPDATE_MY_MAC_HELPER (default <script dir>/lib/cooldown.py)"
}

# Main script execution

# --version and --help must not write a log file or touch any state, so they are
# dispatched before logging is initialised.
for arg in "$@"; do
    case "$arg" in
        --version)
            show_version
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
    esac
done

# Initialize logging
init_logging

# If no arguments, run quick updates (fast updates only)
if [ $# -eq 0 ]; then
    update_quick
    exit 0
fi

# Process command line arguments
#
# Policy flags are pre-scanned so they apply regardless of where they appear
# (e.g. `--brew --bypass uv` must not upgrade uv before the bypass is known).
arg_index=1
while (( arg_index <= $# )); do
    case "${@[arg_index]}" in
        --bypass)
            COOLDOWN_BYPASS="${@[arg_index+1]}"
            (( arg_index += 2 ))
            ;;
        --no-cooldown)
            COOLDOWN_ENFORCE=0
            (( arg_index++ ))
            ;;
        --dry-run)
            DRY_RUN=1
            (( arg_index++ ))
            ;;
        --plugins-force)
            FORCE_PLUGIN_WIPE=1
            (( arg_index++ ))
            ;;
        *)
            (( arg_index++ ))
            ;;
    esac
done

while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            update_all
            ;;
        --quick)
            update_quick
            ;;
        --full)
            update_all
            ;;
        --report|--cooldown-report)
            cooldown_report
            ;;
        --cooldown-status)
            cooldown_status
            ;;
        --cooldown-sync)
            cooldown_sync
            ;;
        --bypass)
            shift   # value consumed by the pre-scan above
            ;;
        --no-cooldown|--dry-run|--plugins-force)
            ;;      # handled by the pre-scan above
        --brew)
            update_brew
            echo -e "\n${GREEN}✓ Brew update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --npm)
            [[ -n "$COOLDOWN_BYPASS" ]] && NPM_BYPASS="$COOLDOWN_BYPASS"
            update_npm
            echo -e "\n${GREEN}✓ npm update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --bun)
            [[ -n "$COOLDOWN_BYPASS" ]] && BUN_BYPASS="$COOLDOWN_BYPASS"
            update_bun
            echo -e "\n${GREEN}✓ Bun update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --uv)
            uv_exit_code=0
            [[ -n "$COOLDOWN_BYPASS" ]] && UV_BYPASS="$COOLDOWN_BYPASS"
            if update_uv; then
                echo -e "\n${GREEN}✓ uv update completed${NC}"
            else
                uv_exit_code=$?
            fi
            show_log_info
            analyze_log
            (( uv_exit_code == 0 )) || exit "$uv_exit_code"
            ;;
        --plugins)
            update_plugins
            echo -e "\n${GREEN}✓ Plugin state check completed${NC}"
            show_log_info
            analyze_log
            ;;
        --appstore)
            update_appstore
            echo -e "\n${GREEN}✓ App Store updates completed${NC}"
            show_log_info
            analyze_log
            ;;
        --xcode)
            update_xcode
            echo -e "\n${GREEN}✓ Xcode update check completed${NC}"
            show_log_info
            analyze_log
            ;;
        --system)
            update_system
            echo -e "\n${GREEN}✓ System update check completed${NC}"
            show_log_info
            analyze_log
            ;;
        --cleanup)
            cleanup
            echo -e "\n${GREEN}✓ Cleanup completed${NC}"
            show_log_info
            analyze_log
            ;;
        --install)
            install_script || exit 1
            ;;
        --uninstall)
            uninstall_script || exit 1
            ;;
        --version)
            show_version      # handled before logging, kept for completeness
            exit 0
            ;;
        --help)
            show_help         # handled before logging, kept for completeness
            ;;
        *)
            print_error "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

exit 0