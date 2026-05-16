# Tasks — enable-longhorn

**Tracking issue:** TBD

Implementation order. Group 1 lands in a PR with no cluster running. Group 2 runs at the next cluster bring-up.

## Group 1 — repo work (no cluster needed)

### Ansible role

- [ ] 1. Create `ansible/roles/longhorn_disk_prep/` with `defaults/main.yml`, `tasks/main.yml`, `handlers/main.yml`, `README.md`. Inputs: `longhorn_device` (required), `longhorn_mount_path` (default `/var/lib/longhorn`), `longhorn_filesystem` (default `ext4`). Per design.md "Ansible role" section.
- [ ] 2. Wire the role into `ansible/playbooks/cluster.yml` for `hosts: workers`, placed before `rke2_agent`.
- [ ] 3. Confirm `ansible/Makefile inventory` (or whatever renders inventory from Tofu outputs) already exposes per-worker `worker_longhorn_devices`. If not, add the mapping (`tofu output -json worker_longhorn_devices` → host_vars). Single small edit.
- [ ] 4. `ansible-lint roles/longhorn_disk_prep playbooks/cluster.yml` clean. `yamllint` clean.

### Longhorn config

- [ ] 5. Edit `apps/longhorn/values.yaml`:
  - `persistence.defaultClass: true` (was `false`).
  - `defaultSettings.defaultDataPath: "/var/lib/longhorn"` (explicit; chart default but written for clarity).
  - `defaultSettings.replicaSoftAntiAffinity: false` (force replicas onto unique nodes; counter-intuitive name, see design.md).
- [ ] 6. Resolve the upstream-encrypted secrets per design.md "SOPS secret re-encryption" Recommendation A:
  - Delete `apps/longhorn/evanstest.secrets.yaml` and `apps/longhorn/longhorn-crypto.secrets.yaml`.
  - Remove both from `apps/longhorn/kustomization.yaml`'s `resources:` list.
  - Inspect `apps/longhorn/helm_secrets.yaml`. If empty/sample-only, replace with an empty-but-our-key-encrypted file. If it has real values we need, re-encrypt with our recipients.
- [ ] 7. Leave `apps/longhorn/longhorn-crypto-global.sc.yaml` in place (still defined, still in the kustomization), but expect it to be non-functional until a future change creates the per-PVC encryption Secret. Note this in the new runbook.
- [ ] 8. `kustomize build apps/longhorn/` cleanly renders (no missing references).

### deploy.sh

- [ ] 9. Edit the `rke2)` branch (`deploy.sh:162-173`):
  - Replace `app_list=""` with `app_list="longhorn.yaml"`.
  - Delete the TEMPORARY comment block entirely.

### Docs

- [ ] 10. Write `docs/runbooks/longhorn-enablement.md`:
  - Prereqs (Phase 2 substrate up, Phase 3b platform reconciled).
  - Enable: `make play` (idempotent re-run picks up the new role), `./deploy.sh` (with restored app_list).
  - Verify: success-criteria checklist from proposal.md (PVC bind, replica spread, pod-reschedule data survival, mount on the DO volume, idempotent ansible).
  - Rollback: `kubectl -n longhorn-system delete helmrelease longhorn`, remove `longhorn.yaml` from the rke2 case, `umount /var/lib/longhorn` + comment the fstab line. Volume data survives as ext4 on the device.
  - Encrypted-SC note: the `longhorn-crypto-global` StorageClass is defined but non-functional pending a future change to provision its referenced Secret.
- [ ] 11. Write `docs/diagrams/longhorn-topology.md` per the design.md outline. Cross-link from the new runbook and from `do-network.md` (sibling diagram).
- [ ] 12. Update `docs/runbooks/do-bring-up.md` Phase 2 storage section: replace "pointer to Phase 3 for actual Longhorn install" with a link to the new `longhorn-enablement.md`.
- [ ] 13. Update `README.md` Phase 3 row to reflect Longhorn-included status once this lands (today the phase-3 row implies Longhorn is part of Phase 3 — accurate after enablement).

### Close-out group 1

- [ ] 14. Open issue: `Phase 3c — enable Longhorn`. Labels: `phase-3`, `area:storage`, `area:fluxcd`, `priority:normal`. Body: link to this change directory.
- [ ] 15. Open PR with commits grouped by concern (suggest three):
  - `feat(ansible): add longhorn_disk_prep role + wire into cluster.yml`
  - `feat(longhorn): default StorageClass + replica anti-affinity + cleanup vendored secrets`
  - `docs: longhorn enablement runbook + topology diagram`
- [ ] 16. Secrets safe-staging check before push: no plaintext age key, no plaintext Longhorn secret, no kubeconfig.
- [ ] 17. Merge to `main`. Issue stays open until Group 2 validation completes.

## Group 2 — at-bring-up validation (cluster running)

> **Pre-flight:** [#24](https://github.com/geekmush/do-nyc3-rke2-demo/issues/24) (`deploy.sh` second-cluster bring-up) and [#23](https://github.com/geekmush/do-nyc3-rke2-demo/issues/23) (sed-clobber of archive docs) both bite on Group 2 if unfixed. Resolve both before running, or follow the manual recovery captured in the 2026-05-16 unattended-test summary (re-apply `flux/flux-system/` via `kubectl apply -k`, then `flux bootstrap github`, then re-add the SOPS decryption block to `gotk-sync.yaml`).

- [ ] 18. `cd terraform/environments/do-test && make apply`. Confirm 6 droplets + 3 volumes + 1 internal LB. No drift.
- [ ] 19. `cd ansible && make inventory && make play`. Confirm `longhorn_disk_prep` runs successfully on all 3 workers (`changed` on first pass, `changed=0` on rerun).
- [ ] 20. SSH into each worker. Verify:
  - `lsblk` shows the DO volume mounted at `/var/lib/longhorn`.
  - `df -h /var/lib/longhorn` shows ~50 GB ext4.
  - `/etc/fstab` has a `UUID=...` line for the mount with `nofail`.
  - Root volume usage is unchanged from Phase 3b.
- [ ] 21. `cd .. && ./deploy.sh`. Confirm `longhorn.yaml` reconciles successfully via Flux. `flux get helmrelease -n longhorn-system longhorn` → `READY=True` within 5 min.
- [ ] 22. `kubectl get sc`. Expect `longhorn (default)` and `longhorn-crypto-global` (non-default).
- [ ] 23. Apply a test PVC + busybox pod (manifest snippet in the runbook). Verify:
  - PVC binds within 30s.
  - `kubectl -n longhorn-system get volumes.longhorn.io -o wide` shows 3 replicas, one per worker.
  - Pod writes a file, then force-delete the pod with `kubectl delete pod --grace-period=0 --force`. Reschedule lands it on a different worker; the file is still readable.
- [ ] 24. Tear down the test PVC + pod. Confirm Longhorn reaps the volume (`kubectl -n longhorn-system get volumes.longhorn.io` empty).
- [ ] 25. Close tracking issue. Comment links to the PR(s) and to verification command outputs.

## Archive

- [ ] 26. `git mv openspec/changes/enable-longhorn openspec/changes/archive/<YYYY-MM-DD>-enable-longhorn`. Commit `docs(openspec): archive enable-longhorn`.
