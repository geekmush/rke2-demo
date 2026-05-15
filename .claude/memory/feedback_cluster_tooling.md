---
name: Operator cluster tooling preference -- k9s + OpenLens, no Rancher
description: User uses k9s and OpenLens on the workstation for cluster ops, and FluxCD/GitOps for all app delivery. Do not propose Rancher unless multi-cluster management materializes (Phase 4+).
metadata:
  type: feedback
---

For cluster operations and observation, the operator's workflow is:

- **`k9s`** — terminal UI, primary daily driver for inspecting workloads, viewing logs, exec'ing into pods.
- **OpenLens** — desktop GUI when something needs a clickier interface.
- **`kubectl`** — for scripting and one-off commands.
- **FluxCD + GitOps** — for all app delivery (cert-manager, ingress-nginx, external-dns, Longhorn, applications, etc.) via [[reference_work_tracking]]'s devopscoop fluxcd-template, vendored as a git subtree.

**Why:** Stated on 2026-05-15 after a Rancher-install design discussion. The user is familiar/comfortable with k9s + OpenLens, intends to manage all apps via FluxCD, and explicitly said "I do not think Rancher adds any real value at this time." The marginal value of Rancher (multi-cluster mgmt, Helm catalog, RBAC layer) doesn't materialize in a single-cluster GitOps-driven test environment.

**How to apply:**
- Do not propose Rancher in design suggestions, OpenSpec changes, or runbooks unless the user explicitly raises it.
- If a future change would benefit from Rancher (e.g. Phase 4 multi-cluster lands), surface the trade-off as a fresh decision -- don't assume the earlier "no Rancher" call is permanent. The trigger is "do we now have multiple clusters or non-developer users?"
- Prefer documentation that points at k9s/OpenLens for human-friendly cluster inspection rather than reaching for a web UI.
- Cluster-app delivery defaults to "add it to the FluxCD apps tree" rather than "install via Helm in Ansible."

Related memory: [[feedback_commit_style]] (multi-commit PRs with descriptive bodies).
