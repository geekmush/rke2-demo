# DigitalOcean Spaces buckets, one per declared consumer.
#
# Each bucket is provisioned with a consumer-appropriate versioning +
# lifecycle policy. Credentials (the Spaces access key + secret) are
# NOT created by this module -- the operator creates them in the DO
# control panel and supplies them via SOPS-encrypted .tfvars. Reason:
# rotating a Tofu-managed Spaces key implies a `tofu apply` that itself
# uses the key to authenticate -- chicken-and-egg.
#
# Bucket naming: `${cluster_name}-${consumer}`. Consumer names are
# lowercase, hyphen-separated, and stable so adding a consumer at the
# end of the list never re-creates earlier buckets.

locals {
  # Map: consumer name -> bucket name. Stable -> can use as for_each key.
  buckets = {
    for c in var.consumers : c => "${var.cluster_name}-${c}"
  }

  # Per-consumer lifecycle expiration in days. Tofu-state has no
  # expiration (versions kept indefinitely; bucket is small). Other
  # consumers age out per their operator-tunable retention vars.
  expirations = {
    "tofu-state"       = null
    "etcd-snapshots"   = var.etcd_snapshot_retention_days
    "longhorn-backups" = var.longhorn_backup_retention_days
  }
}

resource "digitalocean_spaces_bucket" "this" {
  for_each = local.buckets

  name   = each.value
  region = var.region

  # ACL stays "private". Operator can flip per-bucket via DO panel if a
  # use case requires public-read.
  acl = "private"

  # tofu-state bucket refuses force_destroy (state loss is unrecoverable
  # without external backups). Other consumers destroy cleanly.
  force_destroy = each.key != "tofu-state"

  # Versioning enabled only for tofu-state. Rollback on a bad state
  # push needs prior versions. Etcd snapshots and Longhorn backups
  # have their own append-only history -- versioning would double-bill.
  versioning {
    enabled = each.key == "tofu-state"
  }

  dynamic "lifecycle_rule" {
    for_each = local.expirations[each.key] != null ? [local.expirations[each.key]] : []
    content {
      id      = "expire-old-${each.key}"
      enabled = true

      expiration {
        days = lifecycle_rule.value
      }
    }
  }
}
