# Proposal — enable-longhorn

**Tracking issue:** TBD (open at acceptance, link `phase-3, area:storage, area:fluxcd`).
**Phase:** 3c — Longhorn enablement (closes Phase 3).
**Status:** draft 2026-05-16.

## Why

Phase 2 (`add-do-block-storage`, archived) staged three 50 GB DO Block Storage volumes, one per worker, raw and unmounted, attached and discoverable at stable `/dev/disk/by-id/scsi-0DO_Volume_*` paths via Tofu output `worker_longhorn_devices`. Phase 3a (`add-fluxcd-template-vendor`) vendored the Longhorn HelmRelease + values + StorageClass under `apps/longhorn/`. Phase 3b (`add-fluxcd-bootstrap`, archived) brought the rest of the platform stack online but intentionally left Longhorn out — `deploy.sh:173` sets `app_list=""` in the `rke2` branch, with a TODO comment listing exactly what Phase 3c must finish.

This change finishes Phase 3 by turning Longhorn on against those volumes and making it the cluster's default StorageClass. After it lands, the cluster has a real CSI driver and is ready for stateful workloads — which is the gate for Phase 4 (bare-metal) and for anything else we want to run that needs persistence.

## What this change ships

- **Vendored secret re-encryption** under `apps/longhorn/`: `evanstest.secrets.yaml`, `longhorn-crypto.secrets.yaml`, and `helm_secrets.yaml` re-encrypted with this repo's age recipients (per `.sops.yaml`). They currently decrypt only with the upstream template author's key.
- **Default StorageClass = plain Longhorn** (non-encrypted), `replicaCount=3`, `volumeBindingMode=Immediate`. Flip `apps/longhorn/values.yaml:4` from `persistence.defaultClass: false` to `true`. The encrypted `longhorn-crypto-global.sc.yaml` remains available as an opt-in StorageClass for workloads that want encryption-at-rest, but is no longer the cluster default.
- **Disk wiring** so each Longhorn node consumes its dedicated DO Block Storage volume rather than the OS disk:
  - **Ansible role addition** (`ansible/roles/longhorn_disk_prep/`): mkfs.ext4 the device at `worker_longhorn_devices[<hostname>]` if unformatted, mount at `/var/lib/longhorn`, persist in `/etc/fstab` by `UUID=`. Idempotent. Runs before `rke2_agent`.
  - Longhorn's `defaultDataPath` set to `/var/lib/longhorn` (the chart default — explicit in values.yaml for clarity).
- **`deploy.sh` rke2 branch restoration**: change `app_list=""` to `app_list="longhorn.yaml"` and remove the now-stale TEMPORARY comment block (lines 162-172).
- **Operator runbook** at `docs/runbooks/longhorn-enablement.md`: enable → verify → rollback. Includes the validation steps (PVC bind, replica placement, pod-reschedule data survival).
- **Mermaid diagram** at `docs/diagrams/longhorn-topology.md`: how the DO Block Storage volume → ext4 → `/var/lib/longhorn` → Longhorn replica → PVC chain works on each worker, and how replicas distribute across the three workers.

## Out of scope (explicit non-goals)

- **No backup target.** Longhorn's S3-compatible backup feature stays unconfigured. Separate change once we have a DO Spaces bucket and decide retention policy.
- **No CP-side Longhorn**, by deliberate decision (already locked in Phase 2: workers-only).
- **No V2 data engine.** See "Decisions to lock in" below — V1 + filesystem mode is the conservative pick.
- **No encryption-at-rest by default.** The encrypted StorageClass is offered but not default; the bar for default encryption is operator opt-in, not silent re-encryption of every PVC.
- **No image-registry / monitoring / app-of-apps work.** Phase 4+.
- **No automated CI for this change.** Manual operator validation in the runbook.

## Decisions to lock in (review-driven)

1. **V1 data engine (filesystem mode) on a formatted DO volume**, not V2 (block-device mode) on the raw device.
   - The Phase 2 design's "raw block devices" pick was made before fully accounting for V1-vs-V2 maturity. V2 (block-device mode) is `Beta` in Longhorn 1.10 and adds hugepages / CPU mask requirements that the `s-4vcpu-8gb` workers don't have headroom for. V1 + ext4-on-volume is the documented stable path and what the upstream chart defaults to.
   - The "raw" state from Phase 2 is still useful: it lets Ansible decide the filesystem (ext4) rather than inheriting DO's default (also ext4, but we want the choice on our side).
   - **Reversal cost is low**: if V2 matures, we can `wipefs` + reattach as raw without losing the disk substrate.
2. **Default StorageClass = `longhorn` (plain, 3 replicas, Immediate binding).**
   - Alternative: keep the encrypted `longhorn-crypto-global` as default. Rejected for this phase — encryption adds a key-management dimension that we haven't worked through (the per-volume crypto secret lives under SOPS, key rotation isn't defined).
   - Keep the encrypted SC in the kustomization so operators can request `storageClassName: longhorn-crypto-global` per-PVC when they want it.
3. **Ansible owns disk prep**, not a Longhorn `Node` CR with `disks`.
   - Alternative: post-install kubectl-patch each Longhorn `Node` CR to add the disk at `/dev/disk/by-id/...`. Rejected — that path is imperative-on-top-of-GitOps, and CLAUDE.md groundrule #3 wants everything Ansible-able.
   - `mount` lives in `/etc/fstab`, so a reboot reattaches the disk before Longhorn starts; no dependency on Longhorn knowing the device path.
4. **Mount path is the chart default `/var/lib/longhorn`**, not a custom one.
   - One less thing to override in values.yaml. Matches every Longhorn doc, runbook, and Stack Overflow answer.

## Success criteria

- `flux get helmrelease -n longhorn-system longhorn` reports `READY=True` within 5 min of `./deploy.sh` first reconcile.
- `kubectl get sc` shows two StorageClasses: `longhorn` (default, marked with `(default)`) and `longhorn-crypto-global` (non-default).
- A test PVC with no `storageClassName` set binds against `longhorn`, gets exactly 3 replicas distributed across the three workers (`kubectl -n longhorn-system get volumes.longhorn.io -o wide`).
- A test pod writes data to the PVC, gets force-deleted, reschedules to a different worker, and reads the same data back.
- `ssh worker-N "df -h /var/lib/longhorn"` shows a ~50 GB ext4 filesystem on the DO Block Storage device, NOT the root volume.
- `ssh worker-N "lsblk"` shows the DO volume mounted at `/var/lib/longhorn`; root volume usage is unchanged from Phase 3b baseline.
- `make -C ansible play` is idempotent (`changed=0`) after first apply.
- Runbook + diagram exist and cross-link with `do-bring-up.md` (which already mentions Phase 3).

## Sequencing note

Cluster is currently destroyed for cost savings. Implementation tasks split into two groups:

- **Pre-bring-up (no cluster needed):** secret re-encryption, values.yaml flip, deploy.sh edit, Ansible role, runbook, diagram — all in PR before any cluster work.
- **At-bring-up (cluster on):** `make apply` (Tofu, unchanged from Phase 2), `make play` (now includes the new `longhorn_disk_prep` role), `./deploy.sh` (now includes `longhorn.yaml`), validation per success criteria.

Tracking issue (TBD) stays open until the at-bring-up validation completes successfully, then archive.

## Tracking

Tracking issue: TBD. Predecessor: `add-do-block-storage` (volumes), `add-fluxcd-template-vendor` (Longhorn HelmRelease), `add-fluxcd-bootstrap` (rest of platform). Successor: Phase 4 bare-metal migration (uses Longhorn as the proven storage layer; bare-metal disks replace DO volumes without changing the Longhorn config above).
