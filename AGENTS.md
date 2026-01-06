# AGENTS.md

This file contains guidelines and commands for agentic coding assistants working in this repository.

## Repository Overview

This is a simple shell script repository containing a macOS system update utility. The main file is `update-my-mac.sh`, a comprehensive script that updates various package managers and system components on macOS.

## Build/Lint/Test Commands

Since this is a shell script repository, there are no traditional build/test commands. However, here are the essential commands for working with this codebase:

```bash
# Make the script executable
chmod +x update-my-mac.sh

# Test the script (dry run with help)
./update-my-mac.sh --help

# Test individual components safely
./update-my-mac.sh --brew
./update-my-mac.sh --cleanup

# Shell script linting (if shellcheck is available)
shellcheck update-my-mac.sh
```

## Code Style Guidelines

### Shell Script Conventions

1. **Shebang**: Always use `#!/bin/zsh` at the top of scripts
2. **File Header**: Include metadata in the format:
   ```bash
   # filepath: /path/to/script
   # Description: Brief description of the script
   # Date: Month Day, Year
   # Author: Author name
   ```

3. **Function Naming**: Use snake_case with descriptive names:
   - `print_header()`, `print_success()`, `print_error()`
   - `update_brew()`, `update_npm()`, `update_all()`

4. **Variable Naming**: Use UPPER_SNAKE_CASE for constants and color definitions:
   ```bash
   GREEN='\033[0;32m'
   BLUE='\033[0;34m'
   NC='\033[0m'
   ```

5. **Error Handling**: Always check command existence before execution:
   ```bash
   if ! command -v brew &> /dev/null; then
       print_error "Homebrew is not installed"
       return 1
   fi
   ```

6. **Output Formatting**: Use consistent color-coded output functions:
   - `print_header()` for section titles
   - `print_success()` for completed operations
   - `print_error()` for failures
   - `print_warning()` for important notices

### Code Organization

1. **Function Structure**: Group related functions together:
   - Output functions (print_*): lines 14-32
   - Update functions (update_*): lines 34-171
   - Utility functions (cleanup, show_help): lines 175-198

2. **Main Execution**: Keep main script logic at the bottom:
   - Argument parsing: lines 200-246
   - Default behavior: lines 203-206

### Best Practices

1. **Quoting**: Always quote variables and file paths to handle spaces
2. **Error Codes**: Return appropriate exit codes (0 for success, 1 for errors)
3. **Dependency Checking**: Verify tools exist before using them
4. **User Feedback**: Provide clear, color-coded output for all operations
5. **Help Documentation**: Include comprehensive help text with usage examples

### Adding New Features

When adding new package manager support:

1. Create a new `update_<tool>()` function following the existing pattern
2. Add tool existence check at the beginning
3. Use consistent print functions for status updates
4. Add the new option to the case statement in main script
5. Update the `show_help()` function with the new option

### Testing Guidelines

1. Always test with `--help` first to verify script parsing
2. Test individual components before adding to `update_all()`
3. Verify error handling by running with missing dependencies
4. Check script permissions and executable status

### Documentation Standards

1. Keep README.md concise and focused on end-user usage
2. Include command-line options in help text
3. Document dependency requirements in error messages
4. Use clear, user-friendly language in all output

This repository follows simple, maintainable shell scripting practices with emphasis on user experience through clear output and robust error handling.
