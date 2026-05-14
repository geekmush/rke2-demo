---
name: Keep auto-memory local to the repo
description: Store all auto-memory files inside the repo under .claude/memory/ (with .claude/MEMORY.md index) — never in the global ~/.claude/projects/... path.
type: feedback
---

All auto-memory entries for this project live inside the repository at `.claude/memory/<file>.md`, indexed by `.claude/MEMORY.md`. Do not write to the system default at `~/.claude/projects/C--Users-samho-CC-rke2-demo/`.

**Why:** User wants memories portable with the repo so that other machines, collaborators, and CI surfaces share the same context. Stated explicitly on 2026-05-14 during initial skeleton setup.

**How to apply:** Treat `.claude/memory/` and `.claude/MEMORY.md` (repo-relative) as the canonical memory paths for this project. When creating or updating a memory, write there. If a stale global memory exists, delete it and migrate the content into the repo-local path.
