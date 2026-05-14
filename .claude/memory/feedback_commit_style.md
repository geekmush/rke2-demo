---
name: Prefer multiple focused commits per PR
description: For non-trivial PRs on this repo, split the work into multiple logical commits with descriptive bodies — do not squash into a single commit.
metadata:
  type: feedback
---

When preparing a non-trivial PR on rke2-demo, split the work across **multiple focused commits**, each on one logical chunk (e.g. spec / module / env / docs / wrapper). Each commit gets a descriptive body explaining the *why*, in the conventional-commits subject format (`type(scope): subject`) the existing history uses.

**Why:** Stated explicitly on 2026-05-14 during PR #2 prep: "I prefer multiple commits with more details." Confirmed after I proposed both squash and split approaches. The repo's existing commits (`chore: SOPS secrets, work-tracking scaffolding, repo-portability`, `docs(runbook): Linux workstation setup`, etc.) also follow this pattern — short subject, multi-paragraph body with bullet points, conventional-commits prefix.

**How to apply:**
- For a PR with multiple distinct concerns, propose a commit plan (one commit per logical chunk) and execute it. Don't squash unless the user asks.
- Match the existing body style: terse subject < ~70 chars; body explains *why* and lists notable scope items as bullets; reference the tracking issue at the end (`Tracks issue #N`).
- Groundrule #8 still applies: no `Co-Authored-By: Claude`, no AI-attribution footers.
- See [[feedback_no_ai_attribution]] for the attribution rule and [[reference_work_tracking]] for the issue/PR/OpenSpec linkage pattern.
