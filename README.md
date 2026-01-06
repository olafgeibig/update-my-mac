# update-my-mac

A comprehensive macOS system update utility that keeps your development tools and applications up to date with a single command.

## Features

- **Homebrew**: Updates package manager and all installed packages
- **npm**: Updates npm itself and global packages  
- **Bun**: Updates Bun package manager and global packages
- **uv**: Updates uv tool and global Python packages
- **AI Plugins**: Updates OpenCode and Claude Code development tools
- **App Store**: Updates Mac App Store applications (requires mas-cli)
- **Xcode**: Updates Xcode and command line tools
- **System**: Checks for macOS system updates
- **Cleanup**: Removes cached and temporary files
- **Installation**: Installs script system-wide to `/usr/local/bin`
- **🆕 Comprehensive Logging**: Automatic logging of all operations to canonical macOS log locations
- **🆕 Intelligent Analysis**: Automatic LLM analysis using Simon Willison's `llm` tool when available

## Usage

```bash
# Make script executable
chmod +x update-my-mac.sh

# Update everything (default behavior)
./update-my-mac.sh

# Or explicitly
./update-my-mac.sh --all

# Update specific components
./update-my-mac.sh --brew        # Homebrew packages only
./update-my-mac.sh --npm         # npm packages only
./update-my-mac.sh --bun         # Bun packages only
./update-my-mac.sh --uv          # uv packages only
./update-my-mac.sh --plugins     # AI development plugins only
./update-my-mac.sh --appstore    # App Store apps only
./update-my-mac.sh --xcode       # Xcode updates only
./update-my-mac.sh --system      # System updates only
./update-my-mac.sh --cleanup     # Clean caches only

# Install/uninstall script system-wide
./update-my-mac.sh --install     # Install to /usr/local/bin
./update-my-mac.sh --uninstall   # Remove from /usr/local/bin

# Show help
./update-my-mac.sh --help
```

### After Installation

Once installed with `--install`, you can run the script from anywhere:

```bash
# Update everything
update-my-mac

# Update specific components
update-my-mac --bun
update-my-mac --plugins
```

## Requirements

- macOS
- Zsh (default on modern macOS)
- Optional tools for specific features:
  - Homebrew for package management
  - Bun for JavaScript package management
  - uv for Python package management
  - OpenCode for AI development
  - Claude Code for AI development
  - mas-cli for App Store updates (`brew install mas`)
  - **llm** for intelligent log analysis (`pip install llm` - optional)

## Installation

### Local Installation
```bash
# Clone or download the script
chmod +x update-my-mac.sh
./update-my-mac.sh --help
```

### System-wide Installation
```bash
# Install to /usr/local/bin for system-wide access
./update-my-mac.sh --install

# After installation, use from anywhere:
update-my-mac --help

# Uninstall when needed
./update-my-mac.sh --uninstall
```

## Output

The script provides color-coded output:
- 🔵 Blue section headers
- ✅ Green success messages
- ⚠️ Yellow warnings
- ❌ Red error messages

### Logging and Analysis

**Automatic Logging**: All operations are automatically logged to:
```
~/Library/Logs/update-my-mac/update-YYYYMMDD_HHMMSS.log
```

**Log Contents**:
- Timestamped entries with log levels ([INFO], [SUCCESS], [ERROR], [WARNING])
- All commands executed with their full output
- Exit codes and execution duration
- Color codes stripped for clean log files

**Intelligent Analysis**: When Simon Willison's `llm` tool is available, the script automatically:
- Analyzes the complete log file after updates
- Identifies errors, failures, or warnings that need attention
- Provides a summary of what was successfully updated
- Highlights specific manual actions the user needs to take
- Offers recommendations for follow-up maintenance

**Example Analysis Output**:
```
🤖 Analyzing log file with LLM...

### 1. Errors, Failures, or Warnings
- No errors occurred during the update process

### 2. Summary of Updates
- Homebrew: 5 packages updated
- npm: 3 global packages updated
- ✅ All updates completed successfully

### 3. Specific Manual Actions Required
- Xcode command line tools update pending: run `softwareupdate --install --all --agree-to-license`

### 4. Recommendations
- Consider restarting terminal to ensure updated tools are in PATH
```

**Install LLM Tool** (optional):
```bash
pip install llm
```

The script works perfectly without the `llm` tool - analysis is simply skipped with a helpful installation tip.

## Error Handling

The script gracefully handles missing dependencies and provides clear error messages with installation instructions when tools are not available.

## New Features

### 🆕 Comprehensive Logging & Analysis
The script now provides intelligent logging and automatic analysis:
```bash
update-my-mac --all

# Automatic features:
# • Timestamped logging to ~/Library/Logs/update-my-mac/
# • Command execution with exit codes and duration
# • LLM analysis when llm tool is available
# • Error identification and actionable recommendations
```

### Bun Support
The script now supports updating Bun, modern JavaScript runtime and package manager:
```bash
update-my-mac --bun
```

### AI Development Tools
Keep your AI development tools up to date with the new plugins option:
```bash
update-my-mac --plugins
```
This updates both OpenCode and Claude Code if they're installed.

### System-wide Installation
Install the script for system-wide access:
```bash
./update-my-mac.sh --install
```
The script will be available as `update-my-mac` from any directory.

## Changelog

### v1.2.0 - Latest
- ✅ **Added comprehensive logging**: All operations automatically logged to `~/Library/Logs/update-my-mac/`
- ✅ **Added intelligent LLM analysis**: Automatic analysis when `llm` tool is available
- ✅ **Added dual output**: Commands output to both console and log file with timestamps
- ✅ **Added log metadata**: Exit codes, execution duration, and structured log levels
- ✅ **Added automatic log file management**: Unique timestamps, clean formatting, color stripping
- ✅ **Added smart LLM integration**: Detects `llm` tool and runs analysis automatically
- ✅ **Added actionable insights**: Analysis identifies errors, manual actions, and recommendations

### v1.1.0
- ✅ Added Bun package manager support
- ✅ Added AI plugin updates (OpenCode, Claude Code)
- ✅ Added system-wide installation to `/usr/local/bin`
- ✅ Added uninstall functionality
- ✅ Enhanced help documentation
- ✅ Improved error handling for new features

## Troubleshooting

### Viewing Logs
All logs are stored in `~/Library/Logs/update-my-mac/` with timestamped filenames:

```bash
# List all log files
ls -la ~/Library/Logs/update-my-mac/

# View latest log file
less ~/Library/Logs/update-my-mac/update-$(date +%Y%m%d_*.log | tail -1)

# View log with system Console.app
open ~/Library/Logs/update-my-mac/
```

### Log Analysis Without LLM Tool
Even without the `llm` tool, you can manually analyze logs:
```bash
# Search for errors in log
grep -i error ~/Library/Logs/update-my-mac/update-*.log

# Search for warnings
grep -i warning ~/Library/Logs/update-my-mac/update-*.log

# See failed commands
grep "exited with code:" ~/Library/Logs/update-my-mac/update-*.log | grep -v "code: 0"
```

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
