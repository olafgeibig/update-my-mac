---
# update-my-mac-vugm
title: Remove conventional commits dependency
status: completed
type: task
priority: normal
created_at: 2026-01-06T15:30:14Z
updated_at: 2026-01-06T15:32:23Z
---

Modify release workflow to generate changelog from all commits instead of requiring conventional commits format.

1. Replace conventional-changelog-cli with git log based generation
2. Update README to remove strict commit convention requirement