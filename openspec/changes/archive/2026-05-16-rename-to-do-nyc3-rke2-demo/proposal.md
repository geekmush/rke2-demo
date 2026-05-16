# Proposal — rename-to-do-nyc3-rke2-demo

**Tracking issue:** [#20](https://github.com/geekmush/do-nyc3-rke2-demo/issues/20) (closed)
**Phase:** 1 — DO bring-up (post-Phase-3b polish)
**Status:** archived 2026-05-16 -- shipped via [PR #21](https://github.com/geekmush/do-nyc3-rke2-demo/pull/21).

## Why

Rename the project identity from `rke2-demo` to `do-nyc3-rke2-demo` to encode provider (DO) + region (nyc3) + role (rke2-demo). Sets up a coherent naming convention for future clusters (e.g. Phase 4 bare-metal as `bm-onprem-rke2-prod`) and disambiguates this cluster from any future siblings.

The GitHub repo was already renamed (`geekmush/rke2-demo` -> `geekmush/do-nyc3-rke2-demo`) and the local working directory was renamed in lock-step before this change starts. This change updates the cluster identity in the codebase.

## What this change ships

**Behavioral (cluster won't function unless these match the new identity):**

- `variables.sh`:
  - `cluster_name=do-nyc3-rke2-demo`
  - `git_repo=do-nyc3-rke2-demo`
- `terraform/environments/do-test/variables.tf`:
  - `project_name` default `"do-nyc3-rke2-demo"` (drives DO resource names: droplets, LB, firewall, volumes)
- `terraform/environments/do-test/terraform.tfvars.example`:
  - Comment about default `project_name` updated
- `ansible/inventory/group_vars/all/main.yml`:
  - `cluster_name: do-nyc3-rke2-demo`
- `apps/external-dns/values.yaml`:
  - `txtOwnerId: do-nyc3-rke2-demo`
- `ansible/scripts/render-inventory.py`:
  - Default `--key` path `~/.ssh/do_nyc3_rke2_demo_ed25519`
- `ansible/scripts/kube-tunnel.sh`:
  - SSH key default `~/.ssh/do_nyc3_rke2_demo_ed25519`

**Vendored upstream files** (same `s/rke2-demo/do-nyc3-rke2-demo/g` pattern as the original `project1-dev -> rke2-demo` rewrite from Phase 3a):

- `apps/external-dns/values.yaml` (txtOwnerId, covered above)
- `apps/metallb-custom-resources/*.yaml` (3 files; references in IP-pool / l2-advertisement / api-endpointslice)
- `apps/nxrm-ha/values.yaml` (example hostnames)

**Docs:**

- `CLAUDE.md` -- project goal + repository layout references
- `README.md` -- intro + phase plan
- `terraform/README.md` -- layout text
- `docs/runbooks/*.md` -- hardcoded cluster name references in operator commands, examples, paths
- `docs/diagrams/*.md` -- Mermaid labels (`Project: RKE2`, etc.)

## Out of scope (deliberate)

- **DO Project name** in DO UI (`"RKE2"`, looked up by `do_project_name = "RKE2"`). Stays. Generic project grouping; making it cluster-specific commits to a "one DO Project per cluster" model that gets noisy at scale.
- **DNS subdomain** (`rke2-demo.escapekey.org` -- currently delegated to DO DNS via Dreamhost). Stays. The delegation is set up; renaming the subdomain would require new NS records and a new DO DNS zone. (Operator is separately investigating moving all of escapekey.org's DNS to DO since Dreamhost's subdomain delegation has been problematic.)
- **Historical records**:
  - `openspec/changes/archive/**` (project state at each phase)
  - `.claude/memory/**` (operator-preference history)
  - Past commit messages and PR titles (immutable history)
  - `docs/upstream/fluxcd-template-README.md` (archived upstream README)
- **DO infrastructure currently deployed**: destroyed yesterday. New resources at the next `tofu apply` come up under the new names from the start. No live-state migration needed.

## Decisions locked in (from review on 2026-05-15/16)

1. **Cluster name**: `do-nyc3-rke2-demo`. Encodes provider + region + role.
2. **DO Project name**: stays at `"RKE2"`. Operator-managed in the DO UI.
3. **DNS subdomain**: stays at `rke2-demo.escapekey.org`. Separate operator workstream investigating zone-level migration to DO DNS.
4. **SSH key file**: rename `~/.ssh/rke2_demo_ed25519` -> `~/.ssh/do_nyc3_rke2_demo_ed25519` (already done by operator; key content unchanged).
5. **OpenSpec change vs. just-a-PR**: small OpenSpec change. Project-identity rename is a scope refinement; gives the rename a paper trail.

## Success criteria

- After merge + next bring-up, `tofu plan` references `do-nyc3-rke2-demo-cp-01`, `-worker-01-longhorn`, `-cp` (LB), etc. (not `rke2-demo-*`).
- `make -C ansible play` writes the kubeconfig to `~/.kube/do-nyc3-rke2-demo`.
- `external-dns` records use `txtOwnerId: do-nyc3-rke2-demo`.
- Operator-facing docs in `docs/runbooks/*.md` consistently reference the new identity.
- No `rke2-demo` string in production-relevant files (excluding historical archives and `docs/upstream/`).

## Tracking

Issue #20. Depends on the operator having renamed the local directory + git remote (already done before this branch was created). Unblocks the next cluster bring-up under the new identity.
