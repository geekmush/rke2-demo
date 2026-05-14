---
name: No AI attribution in git or GitHub
description: Never add Co-Authored-By Claude, "Generated with Claude Code", or any AI agent attribution to commits, PRs, issues, or review comments in this repo.
type: feedback
---

Do not include Claude or any other AI agent attribution in git commits, pull requests, issue comments, or review comments. This means no `Co-Authored-By: Claude ...` trailer, no "🤖 Generated with Claude Code" footer, no signature lines naming an AI tool.

**Why:** User added this as a project groundrule (groundrule #8 in `CLAUDE.md`) during repo-skeleton setup on 2026-05-14. They want the work authored as the human committer, with no AI fingerprints in repository history or on GitHub.

**How to apply:** When committing, opening PRs, or commenting on GitHub via `gh`, omit the standard Claude Code attribution block entirely. Treat this as overriding the default Claude Code commit-template guidance.
