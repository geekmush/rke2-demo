# Tasks — enable-longhorn

**Tracking issue:** TBD
**Status:** revision 2 (2026-05-17) — see proposal.md "Pre-flight findings"

Implementation order. Group 1 lands in a PR with no cluster running. Group 2 runs at the next cluster bring-up.

## Group 1 — repo work (no cluster needed)

### Fix the broken vendored app

- [ ] 1. Delete the upstream-key-encrypted files we can't decrypt:
  ```
  git rm apps/longhorn/evanstest.secrets.yaml
  git rm apps/longhorn/longhorn-crypto.secrets.yaml
  git rm apps/longhorn/longhorn-crypto-global.sc.yaml
  ```
- [ ] 2. Edit `apps/longhorn/kustomization.yaml`:
  - Remove `evanstest.secrets.yaml`, `longhorn-crypto.secrets.yaml`, `longhorn-crypto-global.sc.yaml` from the `resources:` list.
  - **Remove the entire `secretGenerator:` block** (the reason `helm_secrets.yaml` reference was broken — we have no Helm-values secrets for Longhorn).
- [ ] 3. Edit `apps/longhorn/release.yaml`: bump chart `version: 1.10.0` → `version: 1.11.2`.
- [ ] 4. **Acceptance gate**: `kubectl kustomize apps/longhorn/` MUST render cleanly with no missing-file or unresolved-reference errors. (This is currently broken on main; the test passes only after tasks 1+2.)

### Edit Longhorn values for hard isolation

- [ ] 5. Edit `apps/longhorn/values.yaml`:
  - `persistence.defaultClass: true` (was `false`).
  - `defaultSettings.createDefaultDiskLabeledNodes: true` — opt-in per node; no node gets a disk without an explicit label.
  - `defaultSettings.defaultDataPath: "/var/lib/longhorn"` — explicit; matches the Ansible-managed mount.
  - `defaultSettings.replicaSoftAntiAffinity: false` — hard anti-affinity; force replicas onto unique nodes.
  - `defaultSettings.storageReservedPercentageForDefaultDisk: 0` — dedicated volume, no need to reserve.
  - `defaultSettings.storageMinimalAvailablePercentage: 10` — lower from default 25 since the disk is dedicated.
  - `defaultSettings.upgradeChecker: false` — Flux + chart pin manages upgrades, not in-band notifier.
  - Keep the existing `persistence.defaultClassReplicaCount: 3`.
- [ ] 6. **Acceptance gate**: `kubectl kustomize apps/longhorn/` still renders cleanly with the new values.

### Ansible: render the disk-path inventory + new role

- [ ] 7. Edit `ansible/scripts/render-inventory.py` to emit per-worker `longhorn_device` host_var from Tofu output `worker_longhorn_devices`. The Tofu output is a map of worker hostname → `/dev/disk/by-id/scsi-0DO_Volume_<name>`; render it into each worker's host block as `longhorn_device: <path>`. No new inventory groups; just a per-host var.
- [ ] 8. Run `make -C ansible inventory` (no cluster needed; Tofu state already has the output if the substrate was ever applied) and verify the generated `inventory/generated.yaml` shows `longhorn_device:` lines for each worker.
- [ ] 9. Create `ansible/roles/longhorn_disk_prep/` with:
  - `defaults/main.yml`: `longhorn_mount_path: /var/lib/longhorn`, `longhorn_filesystem: ext4`. `longhorn_device` has no default — required per-host from inventory.
  - `tasks/main.yml` with 7 ordered tasks per design.md "Ansible role" section:
    1. stat the device, fail if missing
    2. inspect existing filesystem (if any)
    3. mkfs.ext4 if needed (no force)
    4. mount via UUID at `/var/lib/longhorn` with `nofail`
    5. chmod 0700 on the mount point
    6. (gated on rke2-agent registered) label the node `node.longhorn.io/create-default-disk=config`
    7. (gated on same) annotate the node `node.longhorn.io/default-disks-config='[{"path":"/var/lib/longhorn","allowScheduling":true,"storageReserved":0,"tags":["dedicated"]}]'`
  - `README.md`: inputs, ordering, idempotency notes, the "why UUID-mount" reasoning.
- [ ] 10. Edit `ansible/playbooks/cluster.yml` (or wherever workers' role order is defined) to add `longhorn_disk_prep` **before** `rke2_agent` for the workers host group.
- [ ] 11. `ansible-playbook --syntax-check -i inventory/generated.yaml playbooks/site.yml` clean. `ansible-lint roles/longhorn_disk_prep` clean. `yamllint roles/longhorn_disk_prep` clean.

### deploy.sh

- [ ] 12. Edit the `rke2)` branch in `deploy.sh`: change `app_list="digitalocean-cloud-controller-manager.yaml"` to `app_list="digitalocean-cloud-controller-manager.yaml longhorn.yaml"`. (Order matters for log readability, not for reconcile — they're parallel.) Remove any TEMPORARY-Phase-3b comment fossils.

### Docs

- [ ] 13. Write `docs/runbooks/longhorn-enablement.md`:
  - Prereqs: Phase 2 substrate up (3× 50GB DO Block Storage volumes attached), Phase 3b platform reconciled (Flux + cert-manager + external-dns + ingress-nginx), Phase 3d CCM running.
  - Enable: `make -C ansible play` (idempotent re-run picks up `longhorn_disk_prep`), `./deploy.sh` (with `longhorn.yaml` in `app_list`).
  - Verify (success-criteria from proposal.md, including the hard-isolation checks).
  - Rollback: `kubectl -n longhorn-system delete helmrelease longhorn` + remove `longhorn.yaml` from deploy.sh app_list + unmount + comment fstab. Volume data survives as ext4 on the device.
  - **Operational caveat — encrypted SC removed in this change**. Future encryption-at-rest needs a separate proposal with explicit key-management.
- [ ] 14. Write `docs/diagrams/longhorn-topology.md` per design.md outline. Cross-link from new runbook and from `do-network.md` + `public-traffic-path.md`.
- [ ] 15. Update `docs/runbooks/do-bring-up.md` "Phase 2 storage" section: change pointer from "Phase 3 will install Longhorn" to "Phase 3c installs Longhorn — see longhorn-enablement.md."
- [ ] 16. Update `README.md` Phase-3 row (if it implies Longhorn isn't yet present): mark Longhorn as installed.
- [ ] 17. Update `docs/TROUBLESHOOTING.md` with a Longhorn section (currently doesn't have one). Cover at minimum: replica scheduling stuck, PVC stays Pending, Longhorn manager pods Pending (toleration/taint), disk path on wrong volume (the hard-isolation check failing).

### Close-out Group 1

- [ ] 18. Verify secrets safe-staging before push: no plaintext age key, no `.decrypted` files staged, no kubeconfig in the diff.
- [ ] 19. Open issue: `Phase 3c — enable Longhorn`. Labels: `type:task`, `phase-3`, `area:longhorn`, `area:fluxcd`, `area:ansible`, `priority:normal`. Body: link to this proposal directory.
- [ ] 20. Open PR with commits grouped:
  - `fix(longhorn): delete upstream-key-encrypted vendored files + bump chart 1.10.0 -> 1.11.2`
  - `feat(longhorn): hard-isolation values (createDefaultDiskLabeledNodes=true + workers-only opt-in)`
  - `feat(ansible): longhorn_disk_prep role + render-inventory `longhorn_device` per-worker`
  - `docs: longhorn-enablement runbook + topology diagram + TROUBLESHOOTING section`
- [ ] 21. PR description includes the kustomize-build-was-broken-on-main finding (the missing `helm_secrets.yaml`), so reviewers understand why deleting files is part of "enabling" Longhorn rather than "breaking" it.
- [ ] 22. Merge to `main`. Issue stays open until Group 2 validation completes.

## Group 2 — at-bring-up validation (cluster running)

Pre-flight: all install-do-ccm-era fixes are landed on main as of 2026-05-17. No outstanding blockers.

- [ ] 23. `cd terraform/environments/do-test && make apply` — same 16 resources as test-#8 envelope.
- [ ] 24. `cd ansible && make inventory && make play` — confirm:
  - `failed=0 unreachable=0` for all 6 hosts.
  - `longhorn_disk_prep` role runs successfully on all 3 workers (`changed` on first pass, `changed=0` on rerun).
  - SSH into one worker: `lsblk -f` shows the DO volume mounted at `/var/lib/longhorn` with UUID-based fstab line + `nofail` option.
- [ ] 25. `cd .. && ./deploy.sh` — fully unattended (per test-#7/#8 baselines). `flux get all -A` shows everything Ready including `longhorn` HelmRelease + Kustomization.
- [ ] 26. **CCM-untaint wait**: Longhorn DaemonSet pods may sit Pending briefly while CCM untaints nodes. Should clear within ~60s. `kubectl -n longhorn-system get pods -o wide` shows everything Running.
- [ ] 27. **Hard-isolation acceptance gates** (NEW in revision 2):
  ```bash
  # Only one disk path across all Longhorn nodes, and it's /var/lib/longhorn:
  kubectl -n longhorn-system get nodes.longhorn.io -o json \
    | jq -r '.items[].spec.disks | to_entries[] | .value.path' | sort -u
  # Expect EXACTLY: /var/lib/longhorn   (no other lines)

  # Only 3 Longhorn Node CRs (workers, NOT CPs):
  kubectl -n longhorn-system get nodes.longhorn.io
  # Expect 3 rows.

  # Disk capacity reflects the 50GB volume, not the 80GB droplet OS disk:
  kubectl -n longhorn-system get nodes.longhorn.io -o json \
    | jq -r '.items[] | "\(.metadata.name): \(.status.diskStatus[].storageMaximum / 1073741824 | floor) GiB"'
  # Expect ~50 GiB per worker.

  # On a worker, confirm the mount lineage:
  ssh worker-N 'findmnt /var/lib/longhorn; lsblk -f'
  # Expect: mounted from /dev/sda or /dev/sdb (DO volume), NOT /dev/vda (OS).
  ```
  If any of these fail, **stop and debug** — the proposal's isolation guarantee isn't holding.
- [ ] 28. `kubectl get sc` shows `longhorn (default)` and nothing else Longhorn-related. (No `longhorn-crypto-global` — we deleted it.)
- [ ] 29. End-to-end PVC test (snippet in runbook): apply a 1Gi PVC with no `storageClassName` annotation. Verify:
  - PVC binds within 30s.
  - `kubectl -n longhorn-system get volumes.longhorn.io` shows the volume.
  - `kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=<vol>` shows 3 replicas, distinct `.spec.nodeID` (hard anti-affinity working).
  - A test pod writes a file, gets force-deleted, reschedules to a different worker, reads the file back.
- [ ] 30. Tear-down test: delete the test PVC + pod. `kubectl -n longhorn-system get volumes.longhorn.io` becomes empty within ~30s.
- [ ] 31. `make -C ansible play` again — `changed=0` proves idempotency end-to-end.
- [ ] 32. `make -C terraform destroy` — `Resources: 16 destroyed`, exit 0, VPC retained (per #29).
- [ ] 33. Close tracking issue. Comment with verification command outputs.

## Archive

- [ ] 34. `git mv openspec/changes/enable-longhorn openspec/changes/archive/<YYYY-MM-DD>-enable-longhorn`. Commit `docs(openspec): archive enable-longhorn`.
