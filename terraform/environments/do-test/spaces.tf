# DigitalOcean Spaces buckets for object-store-backed consumers
# (Tofu remote state, RKE2 etcd snapshots, Longhorn backups).
# See openspec/changes/enable-s3-object-store/ for design + sequencing.

module "spaces" {
  count = var.object_store_provider == "do_spaces" ? 1 : 0

  source = "../../modules/do-spaces"

  cluster_name                   = var.project_name
  region                         = var.object_store_region
  etcd_snapshot_retention_days   = var.etcd_snapshot_retention_days
  longhorn_backup_retention_days = var.longhorn_backup_retention_days
}
