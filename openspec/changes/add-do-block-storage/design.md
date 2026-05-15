# Design — add-do-block-storage

**Tracking issue:** [#11](https://github.com/geekmush/rke2-demo/issues/11)

## File layout (additions only)

```
terraform/modules/do-droplet-infra/
├── ... (existing files unchanged)
└── longhorn_volumes.tf        # new -- volumes + attachments
```

`variables.tf`, `outputs.tf`, and `project.tf` each gain a small block; the module is otherwise unchanged.

## Resource shape

```hcl
resource "digitalocean_volume" "longhorn" {
  count                   = var.worker_count
  name                    = "${digitalocean_droplet.worker[count.index].name}-longhorn"
  region                  = var.region
  size                    = var.longhorn_volume_size_gb
  initial_filesystem_type = null        # raw block device -- no FS
  description             = "Longhorn data disk for ${digitalocean_droplet.worker[count.index].name}"
  tags                    = concat(local.base_tags, ["role:longhorn-disk"])
}

resource "digitalocean_volume_attachment" "longhorn" {
  count      = var.worker_count
  droplet_id = digitalocean_droplet.worker[count.index].id
  volume_id  = digitalocean_volume.longhorn[count.index].id
}
```

### Why no `initial_filesystem_type`

Explicit `null` (rather than omitted) so the intent is visible. DO defaults to ext4 when this is unset on first apply, which would force Longhorn into filesystem-mode. Setting `null` keeps the disk raw, matching Longhorn's preferred block-device mode.

### Why 1:1 worker-to-volume

- Longhorn cannot multi-claim a device.
- DO Block Storage doesn't multi-attach a volume across droplets.
- `count = var.worker_count` ties the two pools together; `worker[i]` always gets `longhorn[i]`.

### Worker-suffixed volume names

`"${digitalocean_droplet.worker[count.index].name}-longhorn"` -> `rke2-demo-worker-01-longhorn`, `rke2-demo-worker-02-longhorn`, `rke2-demo-worker-03-longhorn`. The DO UI displays the volume next to its owner droplet, which matters when a single worker has storage issues.

## Stable device path

DO exposes attached volumes at `/dev/disk/by-id/scsi-0DO_Volume_<volume-name>`. We surface that path in `worker_longhorn_devices` rather than `/dev/sda`-style kernel names -- those can shuffle on reboot if multiple disks come up in non-deterministic order.

Output shape:

```hcl
output "worker_longhorn_devices" {
  description = "Map of worker hostname -> stable Longhorn device path (DO by-id). Consumed by FluxCD-managed Longhorn config in Phase 3."
  value = {
    for i, d in digitalocean_droplet.worker :
    d.name => "/dev/disk/by-id/scsi-0DO_Volume_${digitalocean_volume.longhorn[i].name}"
  }
}
```

Example value:

```
{
  "rke2-demo-worker-01" = "/dev/disk/by-id/scsi-0DO_Volume_rke2-demo-worker-01-longhorn"
  "rke2-demo-worker-02" = "/dev/disk/by-id/scsi-0DO_Volume_rke2-demo-worker-02-longhorn"
  "rke2-demo-worker-03" = "/dev/disk/by-id/scsi-0DO_Volume_rke2-demo-worker-03-longhorn"
}
```

## Project attachment

`digitalocean_project_resources.this.resources` is extended to include the volume URNs. The current list is droplets-only; new list:

```hcl
resources = concat(
  digitalocean_droplet.cp[*].urn,
  digitalocean_droplet.worker[*].urn,
  digitalocean_volume.longhorn[*].urn,
)
```

This keeps the DO Project's resource view consistent: everything that belongs to this cluster shows up under the "RKE2" project.

## Risks / open questions

- **DO Block Storage availability** in nyc3 is generally fine, but the first apply will confirm.
- **Volume resize path**: changing `longhorn_volume_size_gb` later. DO volume `size` is non-destructive (volumes grow in place); Longhorn handles the resize at its level once notified. Confirmed in the runbook.
- **`tofu destroy` semantics**: destroying a volume with Longhorn data on it loses that data. Not a concern in this change (no data yet), but worth a runbook callout once Longhorn is installed.
- **Cost** scales linearly with worker count -- if we ever go to 5 workers, that's +$10/mo just for Longhorn substrate. Documented.

## Hand-off contract to Phase 3 (FluxCD-managed Longhorn install)

The Longhorn HelmRelease landing in Phase 3 needs:

- Stable device paths for each worker -- consumed via `worker_longhorn_devices` output (rendered into FluxCD's per-cluster config or into an Ansible-generated ConfigMap).
- Confirmation that disks are raw (no FS, no mount) -- documented in the runbook.
- Cluster-side node-label or annotation to tell Longhorn which nodes participate. The `role:worker` tag on droplets translates to a node label that the rke2_agent role sets on the kubelet; Longhorn's helm values can use a `nodeSelector` referencing that label.

None of this is implemented in this change -- just listed so the contract is explicit when Phase 3 work starts.
