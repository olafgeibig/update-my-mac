---
# update-my-mac-jvqs
title: Add comprehensive logging feature to update-my-mac.sh
status: completed
type: feature
priority: normal
created_at: 2026-01-06T13:21:51Z
updated_at: 2026-01-06T14:10:57Z
---

Implement a comprehensive logging system for update-my-mac.sh with automatic analysis using Simon Willison's LLM tool

## Checklist

- [ ] **Implement core logging infrastructure**
  - [ ] Add global log file variable pointing to `~/Library/Logs/update-my-mac/update-$(date +%Y%m%d_%H%M%S).log`
  - [ ] Create log directory if it doesn't exist
  - [ ] Create logging functions that capture both stdout and stderr
  - [ ] Add timestamp and metadata to all log entries
  - [ ] Implement log file initialization with proper headers

- [ ] **Update all print functions to support dual output**
  - [ ] Modify `print_header()`, `print_success()`, `print_error()`, `print_warning()` to write to both console and log
  - [ ] Ensure color codes are stripped from log entries (using `sed -r "s/\x1b\[[0-9;]*m//g"`)
  - [ ] Add log level indicators: [INFO], [SUCCESS], [ERROR], [WARNING]

- [ ] **Add comprehensive command execution logging**
  - [ ] Create wrapper function `log_command()` that executes and logs commands
  - [ ] Capture command output, errors, and exit codes
  - [ ] Log command execution time with `time` command or `$SECONDS`
  - [ ] Replace all direct command calls with `log_command()` wrapper

- [ ] **Implement automatic LLM analysis**
  - [ ] Check if `llm` command is available with `command -v llm &> /dev/null`
  - [ ] Create `analyze_log()` function that runs LLM analysis automatically
  - [ ] Use prompt: "Analyze this update log and: 1) Identify any errors or failures, 2) Summarize what was updated successfully, 3) Highlight any manual actions the user needs to take"
  - [ ] Pipe log file to LLM: `cat "$LOG_FILE" | llm "$ANALYSIS_PROMPT"`
  - [ ] Run analysis automatically at the end of all updates when `llm` is available

- [ ] **Implement log file output at completion**
  - [ ] Display full path to log file after all updates complete
  - [ ] Show log file size and line count
  - [ ] Provide clear instructions: "View full log: less $LOG_FILE"
  - [ ] Show whether analysis was run or skipped (if llm not available)

- [ ] **Testing and validation**
  - [ ] Test logging with all update functions individually
  - [ ] Test log file creation and permissions in `~/Library/Logs/`
  - [ ] Test automatic LLM analysis functionality
  - [ ] Verify color codes are properly stripped from logs
  - [ ] Test graceful handling when llm tool is not installed

## Implementation Details

### Log File Location
- Path: `~/Library/Logs/update-my-mac/update-YYYYMMDD_HHMMSS.log`
- Uses timestamp for unique filenames
- Follows macOS user logs convention
- No sudo permissions required

### Automatic LLM Analysis
- Check: `if command -v llm &> /dev/null; then` - run analysis, otherwise skip
- Uses default model configured in user's LLM tool
- Analysis runs automatically after all updates complete
- Clear messaging about whether analysis was performed

### Analysis Flow
1. After all update operations complete
2. Check for `llm` tool availability
3. If available: run analysis and display results
4. If not available: show message about optional llm tool installation

### Log Format
```
[2026-01-06 13:21:51] [INFO] ==== Updating Homebrew packages ====
[2026-01-06 13:21:52] [CMD]  brew update
[2026-01-06 13:21:55] [OUT]  Already up-to-date.
[2026-01-06 13:21:55] [EXIT]  brew update exited with code: 0
[2026-01-06 13:21:55] [SUCCESS] ✓ Homebrew update completed
```

### Command Wrapper Function
```bash
log_command() {
    local cmd="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CMD]  $cmd" | tee -a "$LOG_FILE"
    local start_time=$SECONDS
    eval "$cmd" 2>&1 | while IFS= read -r line; do
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OUT]  $line" | tee -a "$LOG_FILE"
    done
    local exit_code=${PIPESTATUS[0]}
    local duration=$((SECONDS - start_time))
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [EXIT] $cmd exited with code: $exit_code (duration: ${duration}s)" | tee -a "$LOG_FILE"
    return $exit_code
}
```

### Analysis Prompt
```
Analyze this system update log and provide:
1. Any errors, failures, or warning messages that need attention
2. Summary of what was successfully updated 
3. Specific manual actions the user needs to take (like Xcode updates requiring App Store)
4. Any recommendations for follow-up maintenance

Keep responses concise and actionable.
```

### Completion Output Example
```
✓ All updates completed!
📝 Log saved to: /Users/username/Library/Logs/update-my-mac/update-20260106_132155.log
📊 Log size: 15.2KB, 142 lines

🤖 Analyzing log file with LLM...
[LLM analysis output here]

Tip: Install llm tool for automatic analysis: pip install llm
```