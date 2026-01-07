#!/bin/zsh
# filepath: /Users/GEO5BE4/bin/update.sh
# Description: Script to update various software on macOS
# Date: June 6, 2025
# Author: GEO5BE4
VERSION="v2026.01.07"

# Color definitions for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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

# Function to update Homebrew and its packages
update_brew() {
    print_header "Updating Homebrew packages"
    
    # Check if brew is installed
    if ! command -v brew &> /dev/null; then
        print_error "Homebrew is not installed"
        return 1
    fi
    
    # Update brew itself
    log_command "brew update" "Updating Homebrew..."
    
    # Upgrade all packages
    log_command "brew upgrade" "Upgrading Homebrew packages..."
    
    # Cleanup old versions
    log_command "brew cleanup" "Cleaning up old versions..."
    
    print_success "Homebrew update completed"
}

# Function to update npm global packages
update_npm() {
    print_header "Updating npm global packages"
    
    # Check if npm is installed
    if ! command -v npm &> /dev/null; then
        print_error "npm is not installed"
        return 1
    fi
    
    log_command "brew upgrade npm" "Updating npm itself..."
    
    log_command "npm update -g" "Updating global npm packages..."
    
    print_success "npm update completed"
}

# Function to update bun package manager
update_bun() {
    print_header "Updating Bun package manager"
    
    # Check if bun is installed
    if ! command -v bun &> /dev/null; then
        print_error "Bun is not installed"
        return 1
    fi
    
    log_command "bun upgrade" "Updating Bun itself..."
    
    log_command "bun update -g" "Updating global Bun packages..."
    
    print_success "Bun update completed"
}

# Function to update AI development plugins
update_plugins() {
    print_header "Clearing AI development plugin caches"
    
    # Clear opencode plugin cache
    local opencode_cache="$HOME/.cache/opencode/node_modules"
    if [ -d "$opencode_cache" ]; then
        log_command "rm -rf \"$opencode_cache\"" "Clearing OpenCode plugin cache..."
        print_success "OpenCode plugin cache cleared - will reinstall on next startup"
    else
        print_warning "OpenCode plugin cache not found at $opencode_cache"
    fi
    
    # Clear Claude Code plugin cache
    local claude_cache="$HOME/.claude/plugins/cache"
    if [ -d "$claude_cache" ]; then
        log_command "rm -rf \"$claude_cache\"/*" "Clearing Claude Code plugin cache..."
        print_success "Claude Code plugin cache cleared - will reinstall on next startup"
    else
        print_warning "Claude Code plugin cache not found at $claude_cache"
    fi
    
    print_success "Plugin cache clearing completed"
}

# Function to update uv global packages
update_uv() {
    print_header "Updating uv global packages"
    
    # Check if uv is installed
    if ! command -v uv &> /dev/null; then
        print_error "uv is not installed"
        return 1
    fi
    
    log_command "brew upgrade uv" "Updating uv itself..."
    
    log_command "uv tool upgrade --all" "Updating global packages managed by uv..."

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
    log_command "brew cleanup" "Cleaning brew cache..."
    print_success "Cleanup completed"
}

# Function to install script to /usr/local/bin
install_script() {
    print_header "Installing update-my-mac script to /usr/local/bin"
    
    SCRIPT_NAME="update-my-mac"
    TARGET_PATH="/usr/local/bin/$SCRIPT_NAME"
    SOURCE_PATH="$(dirname "$0")/update-my-mac.sh"
    
    # Check if script exists
    if [ ! -f "$SOURCE_PATH" ]; then
        print_error "Source script not found at $SOURCE_PATH"
        return 1
    fi
    
    # Check if target already exists
    if [ -f "$TARGET_PATH" ]; then
        print_warning "Script already exists at $TARGET_PATH"
        echo "Creating backup..."
        sudo cp "$TARGET_PATH" "${TARGET_PATH}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "Backup created"
    fi
    
    # Install the script
    echo "Installing script to $TARGET_PATH..."
    sudo cp "$SOURCE_PATH" "$TARGET_PATH"
    sudo chmod +x "$TARGET_PATH"
    
    print_success "Script installed successfully!"
    echo "You can now run: $SCRIPT_NAME"
    echo "To uninstall, run: sudo rm $TARGET_PATH"
}

# Function to uninstall script from /usr/local/bin
uninstall_script() {
    print_header "Uninstalling update-my-mac script from /usr/local/bin"
    
    SCRIPT_NAME="update-my-mac"
    TARGET_PATH="/usr/local/bin/$SCRIPT_NAME"
    
    # Check if script exists
    if [ ! -f "$TARGET_PATH" ]; then
        print_error "Script not found at $TARGET_PATH"
        return 1
    fi
    
    # Remove the script
    echo "Removing script from $TARGET_PATH..."
    sudo rm "$TARGET_PATH"
    
    print_success "Script uninstalled successfully!"
}

# Show help message
show_help() {
    echo "Usage: update.sh [OPTIONS]"
    echo "Update various software on your macOS system."
    echo ""
    echo "Options:"
    echo "  --quick      Run quick updates only (brew, npm, bun, uv, plugins) - default"
    echo "  --full       Update everything (includes appstore, xcode, system)"
    echo "  --all        Update everything (alias for --full)"
    echo "  --brew       Update Homebrew and its packages"
    echo "  --npm        Update npm and global npm packages"
    echo "  --bun        Update Bun and global Bun packages"
    echo "  --uv         Update uv and global uv packages"
    echo "  --plugins    Clear AI development plugin caches (forces reinstall on next startup)"
    echo "  --appstore   Update App Store applications (requires mas-cli)"
    echo "  --xcode      Update Xcode and command line tools"
    echo "  --system     Check for macOS system updates"
    echo "  --cleanup    Clean up cached and temporary files"
    echo "  --install    Install script to /usr/local/bin for system-wide use"
    echo "  --uninstall  Remove script from /usr/local/bin"
    echo "  --version    Display version information"
    echo "  --help       Display this help message"
}

# Main script execution

# Initialize logging
init_logging

# If no arguments, run quick updates (fast updates only)
if [ $# -eq 0 ]; then
    update_quick
    exit 0
fi

# Process command line arguments
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
        --brew)
            update_brew
            echo -e "\n${GREEN}✓ Brew update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --npm)
            update_npm
            echo -e "\n${GREEN}✓ npm update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --bun)
            update_bun
            echo -e "\n${GREEN}✓ Bun update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --uv)
            update_uv
            echo -e "\n${GREEN}✓ uv update completed${NC}"
            show_log_info
            analyze_log
            ;;
        --plugins)
            update_plugins
            echo -e "\n${GREEN}✓ Plugin cache clearing completed${NC}"
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
            install_script
            ;;
        --uninstall)
            uninstall_script
            ;;
        --version)
            echo "update-my-mac version $VERSION"
            exit 0
            ;;
        --help)
            show_help
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