---
# update-my-mac-b8bq
title: Add plugin update support for opencode and claude code
status: completed
type: feature
priority: normal
created_at: 2026-01-06T13:01:56Z
updated_at: 2026-01-06T13:07:37Z
---

Add functionality to update opencode and claude code plugins to keep AI development tools current.
## Checklist
- [ ] Research how opencode and claude code plugins are installed/updated
- [ ] Determine if they use npm, bun, or other package managers
- [ ] Create update_plugins() function
- [ ] Add specific update logic for opencode plugin
- [ ] Add specific update logic for claude code plugin
- [ ] Include plugin updates in update_all() function
- [ ] Add --plugins option to argument parsing
- [ ] Update help text with plugin option
- [ ] Test plugin update functionality