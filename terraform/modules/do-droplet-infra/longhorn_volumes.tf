# Per-worker DigitalOcean Block Storage volumes staged for Longhorn.
#
# Created raw (no filesystem, no mount) so Longhorn can consume them in
# block-device mode in Phase 3 when FluxCD installs the Longhorn chart.
# Pre-formatting forces Longhorn into filesystem-mode, which is the
# less-efficient fallback path.
#
# 1:1 worker-to-volume because Longhorn doesn't multi-claim a device and
# DO doesn't multi-attach a volume across droplets.
#
# CPs deliberately get no volume -- Longhorn-on-CP contends with etcd I/O.
# See openspec/changes/add-do-block-storage/design.md.

resource "digitalocean_volume" "longhorn" {
  count = var.worker_count

  name   = "${digitalocean_droplet.worker[count.index].name}-longhorn"
  region = var.region
  size   = var.longhorn_volume_size_gb

  # Explicit null so the "raw block device" intent is visible. DO defaults
  # to ext4 if this is unset on first apply, which would force Longhorn
  # into filesystem-mode.
  initial_filesystem_type = null

  description = "Longhorn data disk for ${digitalocean_droplet.worker[count.index].name}"
  tags        = concat(local.base_tags, ["role:longhorn-disk"])
}

resource "digitalocean_volume_attachment" "longhorn" {
  count = var.worker_count

  droplet_id = digitalocean_droplet.worker[count.index].id
  volume_id  = digitalocean_volume.longhorn[count.index].id
}
