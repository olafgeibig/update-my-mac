---
# update-my-mac-3i9q
title: Add update profiles (quick/full) to skip slow updates
status: in-progress
type: feature
created_at: 2026-01-07T19:14:14Z
updated_at: 2026-01-07T19:14:14Z
---

Add preset update profiles to make system updates more convenient:

## Problem
Running update-my-mac.sh without arguments runs ALL updates including slow Xcode, App Store, and System updates which can take very long.

## Solution
Add preset profiles:
- **--quick**: Run only fast updates (brew, npm, bun, uv, plugins) - ~1-2 minutes
- **--full**: Run all updates (same as current --all)
- Change default behavior to run quick updates instead of all updates

## Checklist
- [x] Create update_quick() function with only fast updates
- [x] Keep update_all() unchanged (runs everything)
- [x] Change default behavior in main script to call update_quick()
- [x] Add --quick option to case statement
- [x] Add --full option to case statement (same as --all)
- [x] Update help message to document new options
- [x] Test with --quick flag
- [x] Test with --full flag
- [x] Test default (no arguments) behavior
- [x] Verify help message is correct