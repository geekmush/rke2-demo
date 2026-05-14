---
name: Work tracking — GitHub Issues now, Gitea-compatible later
description: Active backlog/tasks live in GitHub Issues on geekmush/rke2-demo. Production environment uses Gitea, which is GitHub-import compatible. OpenSpec handles per-change design artifacts in-repo.
type: reference
---

Work tracking for this repo:

- **GitHub Issues on `geekmush/rke2-demo`** — backlog, bugs, ideas, milestones, discussion. Labels are scoped by phase and component (e.g. `phase-1`, `tofu`, `ansible`, `rke2`, `longhorn`, `docs`).
- **OpenSpec under `openspec/changes/<name>/`** — per-change proposal, design, and tasks. An OpenSpec change is referenced from its tracking issue, not duplicated.
- **Gitea (production environment)** — Gitea ships a GitHub→Gitea importer covering issues, labels, milestones, PRs, and comments, so anything filed on GitHub now is portable. `tea` CLI is the Gitea equivalent of `gh`.

**How to apply:** When the user describes work to do, default to filing/updating a GitHub Issue (don't just add it to a TODO list). For implementation-shape changes, also create an OpenSpec change and link the two. Avoid double-tracking task lists between Issues and OpenSpec `tasks.md` — Issues are "what to do," OpenSpec is "how this specific change is designed."
