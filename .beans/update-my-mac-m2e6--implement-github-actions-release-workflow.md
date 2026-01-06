---
# update-my-mac-m2e6
title: Implement GitHub Actions Release Workflow
status: in-progress
type: feature
priority: normal
created_at: 2026-01-06T15:22:20Z
updated_at: 2026-01-06T15:23:37Z
---

Create a GitHub Actions workflow to automate releases.

## Objectives
- Trigger on push to main
- Generate date-based versions (vYYYY.MM.DD)
- Generate changelog automatically using conventional commits
- Publish GitHub Release with script and changelog assets

## Plan
1. Create `.github/workflows/release.yml`
2. Configure date-based versioning logic
3. Configure `conventional-changelog` generation
4. Configure `softprops/action-gh-release`