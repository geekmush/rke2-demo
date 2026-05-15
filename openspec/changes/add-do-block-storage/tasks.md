# Tasks — add-do-block-storage

**Tracking issue:** [#11](https://github.com/geekmush/rke2-demo/issues/11)

Implementation order. Each numbered task is a discrete-commit-sized chunk.

## Tofu

- [ ] 1. Add `longhorn_volume_size_gb` variable to `terraform/modules/do-droplet-infra/variables.tf` (number, default 50, description per design.md).
- [ ] 2. Create `terraform/modules/do-droplet-infra/longhorn_volumes.tf`:
  - `digitalocean_volume.longhorn` with `count = var.worker_count`, name derived from worker hostname, raw block device (`initial_filesystem_type = null`).
  - `digitalocean_volume_attachment.longhorn` matching 1:1 to workers.
- [ ] 3. Extend `digitalocean_project_resources.this.resources` in `project.tf` to include the volume URNs.
- [ ] 4. Add `worker_longhorn_devices` output to `terraform/modules/do-droplet-infra/outputs.tf` (map of worker hostname -> `/dev/disk/by-id/...` path).
- [ ] 5. Re-export `worker_longhorn_devices` through `terraform/environments/do-test/outputs.tf`.
- [ ] 6. `tofu fmt -recursive modules/` + `tofu fmt environments/do-test/*.tf`.
- [ ] 7. `make validate`.
- [ ] 8. `make plan` -- expect **3 volumes + 3 attachments + 1 project_resources update**, no droplet recreation. Capture the plan output for the PR.
- [ ] 9. `make apply`. Verify the plan-matches-apply.

## Verification

- [ ] 10. DO web UI -- confirm 3 Block Storage resources in the "RKE2" Project, each attached to its corresponding worker droplet.
- [ ] 11. SSH to each worker, run `lsblk` -- expect a new ~50 GB disk with no filesystem and no mount. Stable device path under `/dev/disk/by-id/scsi-0DO_Volume_*` resolves.
- [ ] 12. `tofu output worker_longhorn_devices` -- map shape matches design.md example.

## Docs

- [ ] 13. Append a "Phase 2 storage substrate" section to `docs/runbooks/do-bring-up.md`: what gets created, the cost, the `lsblk` check, the deliberate "raw / unmounted" state, and a pointer to Phase 3 for the actual Longhorn install.
- [ ] 14. No new runbook file in this change; no Mermaid diagram update (the existing do-network.md is about network topology, not storage). Phase 3's Longhorn change will introduce a storage diagram.

## Close-out

- [ ] 15. Open PR with two commits, per the project's commit-style preference:
  - `feat(terraform): add DO Block Storage volumes for Longhorn` -- all Tofu changes from tasks 1-5.
  - `docs(runbook): block storage verification + Phase 3 pointer` -- task 13.
- [ ] 16. Walk the secrets safe-staging checklist (no plaintext credentials should be involved -- volume creation needs the existing DO token only).
- [ ] 17. Merge. Issue #11 closes automatically.
- [ ] 18. Archive the change directory: `git mv openspec/changes/add-do-block-storage openspec/changes/archive/<date>-add-do-block-storage`.
