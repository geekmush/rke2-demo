# Proposal — add-do-block-storage

**Tracking issue:** [#11](https://github.com/geekmush/rke2-demo/issues/11)
**Phase:** 2 — Storage (Longhorn)
**Status:** proposed

## Why

CLAUDE.md groundrule #4 mandates dedicated disks for Longhorn -- never colocated with the OS disk. Phase 2 stages those disks now so Phase 3 (FluxCD-managed Longhorn install) has dedicated devices to claim, without us reshaping the substrate twice.

This change touches the Tofu side only. The actual Longhorn install lives in the FluxCD apps stack vendored from `devopscoop/fluxcd-template` -- Phase 3.

## What this change ships

- **Module additions** in `terraform/modules/do-droplet-infra/`:
  - `digitalocean_volume.longhorn` with `count = var.worker_count`. 50 GB by default (`var.longhorn_volume_size_gb`), same region as the cluster, raw block device (no filesystem pre-format).
  - `digitalocean_volume_attachment.longhorn` -- 1:1 mapping to workers (volume[i] -> worker[i]).
  - Module output `worker_longhorn_devices`: `map(string)` of `{worker-name -> /dev/disk/by-id/scsi-0DO_Volume_<volume-name>}` so Longhorn / Ansible / FluxCD can reference stable device paths instead of kernel-name guesses.
  - `digitalocean_project_resources.this` extended to include the volume URNs (cleanliness in the DO UI).
- **New module variable** `longhorn_volume_size_gb` (number, default 50). No separate count knob -- workers and their volumes stay 1:1.
- **Env re-export** of `worker_longhorn_devices` through `terraform/environments/do-test/outputs.tf`.
- **Runbook addition** at the bottom of `docs/runbooks/do-bring-up.md`: cost note (~$15/mo), `lsblk` verification step, pointer to Phase 3 for actual Longhorn install.

## Out of scope (explicit non-goals)

- **Workers-only**, by deliberate decision. CPs get no Longhorn volume. Longhorn best practice is to keep storage I/O off etcd nodes.
- **No filesystem, no mount, no cloud-init change.** Longhorn consumes the volumes as raw block devices in Phase 3 (block-device mode is more efficient than filesystem mode; pre-formatting would force the less-efficient path).
- **No Longhorn install.** Phase 3 / FluxCD-managed.
- **No Longhorn backup target.** Longhorn's backup feature points at an S3-compatible bucket -- a Phase 3 decision.

## Decisions locked in (from review on 2026-05-15)

1. **Workers-only** (3 volumes total). Alternative considered: all 6 nodes (Longhorn-on-CP). Rejected for etcd-I/O contention + cost.
2. **50 GB per volume.** Operator-specified for the test phase. Easy to grow later -- DO volume resize is non-destructive.
3. **Raw block devices (no `initial_filesystem_type`).** Longhorn block-device mode is the better default; filesystem mode is a fallback Longhorn supports if we ever need it.
4. **Worker-suffixed naming**: `rke2-demo-worker-01-longhorn`, etc. Operationally, when a single worker has storage issues, the DO UI showing `worker-02-longhorn` next to `worker-02` is a small but real win over generic numbered names.

## Success criteria

- `make -C terraform plan` shows exactly **3 volumes + 3 attachments + 1 project-resources update**; no droplet recreation.
- `make -C terraform apply` succeeds. In the DO web UI, the "RKE2" Project lists 3 new Block Storage resources attached to the workers.
- SSH'ing into any worker: `lsblk` shows a new ~50 GB disk with no filesystem and no mount.
- `tofu output worker_longhorn_devices` returns the expected map.
- Cost increase: ~$15/month ($0.10/GB-month × 50 GB × 3) on top of the droplet baseline.

## Tracking

Issue #11. Depends on PR #2 (droplet module) and PR #7 (RKE2 install / worker inventory). Unblocks Phase 3 FluxCD bootstrap.
