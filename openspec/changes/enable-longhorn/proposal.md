# Proposal — enable-longhorn

**Tracking issue:** TBD (open at acceptance, link `phase-3, area:storage, area:fluxcd`).
**Phase:** 3c — Longhorn enablement (closes Phase 3).
**Status:** draft 2026-05-17 (revision 2 after deeper research — see "Pre-flight findings" below).

## Why

Phase 2 (`add-do-block-storage`, archived) staged three 50 GB DO Block Storage volumes, one per worker, raw and unmounted, attached and discoverable at stable `/dev/disk/by-id/scsi-0DO_Volume_*` paths via Tofu output `worker_longhorn_devices`. Phase 3a (`add-fluxcd-template-vendor`) vendored the Longhorn HelmRelease + values + StorageClass under `apps/longhorn/`. Phase 3b (`add-fluxcd-bootstrap`, archived) brought the rest of the platform stack online but intentionally left Longhorn out — `deploy.sh:173` sets `app_list=""` in the `rke2` branch, with a TODO comment listing exactly what Phase 3c must finish.

This change finishes Phase 3 by turning Longhorn on against those volumes and making it the cluster's default StorageClass. After it lands, the cluster has a real CSI driver and is ready for stateful workloads — which is the gate for Phase 4 (bare-metal) and for anything else we want to run that needs persistence.

## Pre-flight findings (revision 2)

Surfaced during research on 2026-05-17 after the install-do-ccm v3 work landed and the operator asked for "assume the vendored apps/longhorn/ does not work":

1. **`apps/longhorn/` as-shipped fails `kustomize build`.** The vendored `kustomization.yaml` references `helm_secrets.yaml` in `secretGenerator`, but **that file does not exist on disk**:
   ```
   $ kubectl kustomize apps/longhorn/
   error: loading KV pairs: file sources: [values.yaml=helm_secrets.yaml]:
     evalsymlink failure on 'apps/longhorn/helm_secrets.yaml': lstat ...: no such file or directory
   ```
   Without a fix, the Longhorn Flux Kustomization can never reconcile. Either supply the file or remove the `secretGenerator` block entirely. Since we have no Helm-values secrets for Longhorn (no S3 backup target wired up yet), removal is cleaner than an empty-but-encrypted placeholder.
2. **Two of the three vendored `*.secrets.yaml` files are not decryptable by us.** `evanstest.secrets.yaml` (an S3 backup-target credential for the upstream author's test environment) and `longhorn-crypto.secrets.yaml` (a per-volume crypto key) are SOPS-encrypted to the upstream template author's age recipient (`age1hyw8w5...`). Our age key cannot decrypt either. Original revision 1 recommended re-encryption; that's not possible without the plaintext. Recommendation: **delete both** + remove from `kustomization.yaml.resources`. They're upstream sample data, not load-bearing for our install.
3. **Longhorn chart pin should bump 1.10.0 → 1.11.2.** Latest stable as of 2026-05-17 ([releases](https://github.com/longhorn/longhorn/releases/tag/v1.11.2)). v1.11 GA'd parallel replica rebuild and other quality-of-life improvements. v1.12 is in release-candidate; not for us.
4. **V2 data engine status correction (vs revision 1's claim):** V2 is **Technical Preview** in Longhorn 1.11 (not "Beta" as the original revision 1 design.md said). It also requires kernel ≥ 5.19 (6.7+ recommended), specific kernel modules (`vfio_pci`/`uio_pci_generic`/`nvme-tcp`), 2 GiB of 2 MiB hugepages, SSE4.2, and a dedicated CPU core per instance-manager. Our `s-4vcpu-8gb` workers don't have headroom for this on top of the rest of the cluster. **V1 + filesystem-mode is the unambiguous pick** for the test phase; the decision was right but the rationale strengthens.
5. **Hard-isolation pattern recommendation (NEW in revision 2):** the original proposal said "auto-create default disk on every node" + relied on the CP taint to keep CPs out of Longhorn's view. That's fragile — if the CP taint is ever removed (which we may do for some Phase 4 workloads), Longhorn would create a disk on the CP's OS partition. Stricter pattern: **`createDefaultDiskLabeledNodes: true`** in values.yaml so Longhorn auto-creates disks ONLY on nodes labeled `node.longhorn.io/create-default-disk=config`; the Ansible role labels workers post-mount and never touches CPs. Defense in depth — even if CP taints disappear, Longhorn physically cannot create a disk on a node it wasn't told about.

These five findings reshape "What this change ships" and add Decision 5 below.

## What this change ships

- **`apps/longhorn/` cleanup + chart bump**:
  - Delete `apps/longhorn/evanstest.secrets.yaml` and `apps/longhorn/longhorn-crypto.secrets.yaml` (upstream-key-encrypted, unreadable to us).
  - Delete `apps/longhorn/longhorn-crypto-global.sc.yaml` (encrypted StorageClass that depends on `longhorn-crypto.secrets.yaml` — non-functional without it; reintroduce in a future change when encryption-at-rest becomes a real requirement).
  - Edit `apps/longhorn/kustomization.yaml` to remove both deleted resources from the `resources:` list AND remove the entire `secretGenerator:` block (we have no Helm-values secrets — the missing `helm_secrets.yaml` was the cause of the kustomize-build failure).
  - Edit `apps/longhorn/release.yaml`: bump chart version `1.10.0` → `1.11.2`.
- **Default StorageClass = plain Longhorn**, `replicaCount=3`, `volumeBindingMode=Immediate`. `apps/longhorn/values.yaml`:
  - `persistence.defaultClass: true` (was `false`).
  - `defaultSettings.defaultDataPath: "/var/lib/longhorn"` (explicit).
  - `defaultSettings.replicaSoftAntiAffinity: false` (force hard anti-affinity → 3 replicas on 3 distinct workers).
  - **`defaultSettings.createDefaultDiskLabeledNodes: true`** (opt-in per node; no node gets a Longhorn disk unless explicitly labeled).
  - `defaultSettings.storageReservedPercentageForDefaultDisk: 0` (dedicated 50GB volume → no need to reserve any for non-Longhorn usage).
  - `defaultSettings.upgradeChecker: false` (we manage upgrades via Flux + chart-version pin, not via Longhorn's own update notifier).
- **Disk wiring (Ansible)** — `ansible/roles/longhorn_disk_prep/`:
  - mkfs.ext4 the device at `worker_longhorn_devices[<hostname>]` if unformatted; mount at `/var/lib/longhorn`; persist in `/etc/fstab` by UUID; permissions `0700 root:root`.
  - **Add the Longhorn opt-in label + disks-config annotation** post-mount: `node.longhorn.io/create-default-disk=config` label + `node.longhorn.io/default-disks-config='[{"path":"/var/lib/longhorn","allowScheduling":true,"storageReserved":0,"tags":["dedicated"]}]'` annotation. Done via `kubernetes.core.k8s` from the bootstrap CP (which has a working kubeconfig at that point in the play).
  - Idempotent. Runs before `rke2_agent`. Workers-only; CPs never labeled.
- **`ansible/scripts/render-inventory.py`** — emit `worker_longhorn_devices` map from Tofu output into per-worker `longhorn_device` host_vars. Currently the script only emits CP/worker IPs; it needs the per-worker device path so the role knows what to format/mount.
- **`deploy.sh` rke2 branch**: change `app_list=""` (or `app_list="digitalocean-cloud-controller-manager.yaml"` post-#34) to include `longhorn.yaml`. Remove the stale TEMPORARY comment.
- **Operator runbook** at `docs/runbooks/longhorn-enablement.md`: enable → verify → rollback. Includes hard-isolation verification commands (no Longhorn disk paths outside `/var/lib/longhorn`).
- **Mermaid diagram** at `docs/diagrams/longhorn-topology.md`: DO Block Storage volume → ext4 → `/var/lib/longhorn` → Longhorn replica → PVC chain on each worker, and how replicas distribute across the three workers.

## Out of scope (explicit non-goals)

- **No backup target.** Longhorn's S3-compatible backup feature stays unconfigured. Separate change once we have a DO Spaces bucket and decide retention policy.
- **No CP-side Longhorn**, by deliberate decision (already locked in Phase 2: workers-only).
- **No V2 data engine.** See "Decisions to lock in" below — V1 + filesystem mode is the conservative pick.
- **No encryption-at-rest by default.** The encrypted StorageClass is offered but not default; the bar for default encryption is operator opt-in, not silent re-encryption of every PVC.
- **No image-registry / monitoring / app-of-apps work.** Phase 4+.
- **No automated CI for this change.** Manual operator validation in the runbook.

## Decisions to lock in (review-driven)

1. **V1 data engine (filesystem mode) on a formatted DO volume**, not V2 (block-device mode) on the raw device.
   - V2 is **Technical Preview** in Longhorn 1.11 (corrected from revision 1's claim of "Beta"). Requires kernel ≥ 5.19 (6.7+ recommended), specific kernel modules (`vfio_pci`/`uio_pci_generic`/`nvme-tcp`), 2 GiB of 2 MiB hugepages, SSE4.2, and a dedicated CPU core per instance-manager. Our `s-4vcpu-8gb` workers can't reasonably host that on top of the rest of the cluster.
   - V1 + ext4-on-volume is the documented stable path and what the upstream chart defaults to.
   - The "raw" state from Phase 2 is still useful: it lets Ansible decide the filesystem (ext4) rather than inheriting DO's default.
   - **Reversal cost is low**: if V2 GA's, we can `wipefs` + reattach as raw without losing the disk substrate.
2. **Default StorageClass = `longhorn` (plain, 3 replicas, Immediate binding).** Encryption-at-rest is a separate later change.
   - The vendored `longhorn-crypto-global.sc.yaml` is DELETED in this change (its required Secret is unreadable to us). Reintroduce as a separate change when there's a workload demanding encryption-at-rest, designed around a key-management decision we explicitly make rather than the upstream sample.
3. **Ansible owns disk prep**, not a Longhorn `Node` CR `patch` from kubectl.
   - `mount` lives in `/etc/fstab` so a reboot reattaches the disk before Longhorn starts. The Longhorn label + annotation are applied via `kubernetes.core.k8s` from the bootstrap CP, but only AFTER the disk is mounted — same play, ordered.
   - Alternative (rejected): post-install kubectl-patch each Longhorn `Node` CR to add the disk at `/dev/disk/by-id/...`. That path is imperative-on-top-of-GitOps, and CLAUDE.md groundrule #3 wants everything Ansible-able.
4. **Mount path is the chart default `/var/lib/longhorn`**, not a custom one. Less to override, matches every Longhorn doc.
5. **Opt-in node labeling for hard isolation** (NEW in revision 2). `createDefaultDiskLabeledNodes: true` + workers labeled `node.longhorn.io/create-default-disk=config` + workers annotated `node.longhorn.io/default-disks-config='[{"path":"/var/lib/longhorn","allowScheduling":true,"storageReserved":0,"tags":["dedicated"]}]'`. CPs receive neither label nor annotation, so even if their `NoSchedule` taint is ever removed, Longhorn physically cannot create a disk on them. Belt-and-suspenders matching the operator's "must not touch OS disk OR any non-dedicated disk/dir" requirement.
6. **Chart pin v1.11.2** (latest stable as of 2026-05-17). v1.12 is RC-only; not for production-ish use. Bumping the pin is a deliberate operator commit after release-note review.

## Success criteria

- `flux get helmrelease -n longhorn-system longhorn` reports `READY=True` within 5 min of `./deploy.sh` first reconcile.
- `kubectl get sc` shows exactly one Longhorn StorageClass: `longhorn (default)`. (`longhorn-crypto-global` deleted in this change.)
- A test PVC with no `storageClassName` set binds against `longhorn`, gets exactly 3 replicas distributed across the three workers (`kubectl -n longhorn-system get volumes.longhorn.io -o wide` + `kubectl -n longhorn-system get replicas.longhorn.io`).
- A test pod writes data to the PVC, gets force-deleted, reschedules to a different worker, and reads the same data back.
- **Hard isolation check (NEW)** — every Longhorn disk path lives at `/var/lib/longhorn` and nowhere else:
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io -o json | \
    jq -r '.items[].spec.disks | to_entries[] | .value.path' | sort -u
  # Expect: /var/lib/longhorn  (single line, no other paths)
  ```
- **No Longhorn Node CR for CPs** — `kubectl -n longhorn-system get nodes.longhorn.io` shows exactly 3 entries (workers), not 6.
- **Disk capacity ~50 GB** (the DO Block Storage volume), not ~80 GB (the droplet OS disk):
  ```bash
  kubectl -n longhorn-system get nodes.longhorn.io -o json | \
    jq -r '.items[] | "\(.metadata.name): \(.status.diskStatus[].storageMaximum / 1073741824 | floor) GiB"'
  ```
- `ssh worker-N "findmnt /var/lib/longhorn; lsblk -f"` shows the DO volume (`/dev/sda` or `/dev/sdb`) mounted at `/var/lib/longhorn`, NOT `/dev/vda` (OS).
- `ssh worker-N "df -h /var/lib/longhorn"` shows a ~50 GB ext4 filesystem.
- Root volume usage unchanged from Phase 3b baseline.
- `make -C ansible play` is idempotent (`changed=0`) after first apply.
- Runbook + diagram exist and cross-link with `do-bring-up.md`.

## Sequencing note

Cluster is currently destroyed for cost savings. Implementation tasks split into two groups:

- **Pre-bring-up (no cluster needed):** secret re-encryption, values.yaml flip, deploy.sh edit, Ansible role, runbook, diagram — all in PR before any cluster work.
- **At-bring-up (cluster on):** `make apply` (Tofu, unchanged from Phase 2), `make play` (now includes the new `longhorn_disk_prep` role), `./deploy.sh` (now includes `longhorn.yaml`), validation per success criteria.

Tracking issue (TBD) stays open until the at-bring-up validation completes successfully, then archive.

## Known blockers / related work

All of revision 1's listed blockers (#23, #24, #25, #26) are **resolved as of 2026-05-17** — they were the test #2 fix queue plus the install-do-ccm work, all merged. No outstanding blockers for Group 2.

Sibling completed work that interacts with this change:
- **install-do-ccm** (archived `2026-05-17-install-do-ccm`) added the `node.cloudprovider.kubernetes.io/uninitialized` taint to every node at bring-up. The Longhorn DaemonSet doesn't have a special toleration for this — it'll wait for CCM to untaint nodes before scheduling, which adds ~30-60s to the Longhorn-comes-up phase. This is normal and self-resolving.
- **#44** (closed not-planned, see issue) — external-dns orphan-TXT bug. Doesn't affect Longhorn directly. Operator workaround in `docs/runbooks/install-do-ccm.md` if needed during canary verification.

## Tracking

Tracking issue: TBD. Predecessor: `add-do-block-storage` (volumes), `add-fluxcd-template-vendor` (Longhorn HelmRelease), `add-fluxcd-bootstrap` (rest of platform), `install-do-ccm` (CCM + LB substrate that any Longhorn-backed Service uses if it needs LB exposure). Successor: Phase 4 bare-metal migration (uses Longhorn as the proven storage layer; bare-metal disks replace DO volumes without changing the Longhorn config above — the `longhorn_disk_prep` Ansible role's only input is a device path, provider-agnostic).
