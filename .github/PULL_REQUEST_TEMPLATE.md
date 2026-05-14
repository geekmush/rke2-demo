<!--
  Reminder: per groundrule #8, do NOT include AI-tool attribution
  (no "Co-Authored-By: Claude", no "Generated with Claude Code", etc.).
-->

## Summary

<!-- One paragraph: what changes and why. -->

## Closes / relates to

- Closes #
- OpenSpec change: `openspec/changes/<name>/` (if applicable)

## Phase

<!-- phase-1 / phase-2 / phase-3 / phase-4 / phase-5 / cross-phase -->

## Verification

<!-- How the change was tested. Commands run, droplets touched, plan output, etc. Scrub secrets from any pasted output. -->

- [ ] `tofu fmt` / `tofu validate` clean (if Tofu touched)
- [ ] `ansible-lint` clean (if Ansible touched)
- [ ] Manual verification described above

## Groundrule check

- [ ] No plaintext secrets added (SOPS `*.enc.*` only — groundrule #9)
- [ ] No AI-tool attribution in commits or this PR body (groundrule #8)
- [ ] Docs updated: README / runbook / diagram as needed (groundrule #7)
- [ ] Non-trivial design changes have a matching OpenSpec proposal (groundrule #6)
