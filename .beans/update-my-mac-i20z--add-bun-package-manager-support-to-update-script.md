---
# update-my-mac-i20z
title: Add bun package manager support to update script
status: completed
type: feature
priority: normal
created_at: 2026-01-06T13:01:51Z
updated_at: 2026-01-06T13:06:13Z
---

Add support for updating bun package manager and its global packages to the update-my-mac script.
## Checklist
- [ ] Research bun update commands and best practices
- [ ] Create update_bun() function following existing pattern
- [ ] Add bun dependency check
- [ ] Include bun in update_all() function
- [ ] Add --bun option to argument parsing
- [ ] Update help text to include bun option
- [ ] Test bun update functionality