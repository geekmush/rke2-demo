variable "cluster_name" {
  description = "Resource-name prefix. Drives bucket names: var.cluster_name plus a dash plus each consumer name. Matches the cluster identity used elsewhere (Ansible group_vars cluster_name, root env project_name)."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug for the Spaces buckets. Spaces regions are a SUBSET of droplet regions — verify the chosen region supports Spaces before applying. Typical: \"nyc3\", \"sfo3\", \"ams3\", \"sgp1\", \"fra1\", \"syd1\"."
  type        = string
}

variable "consumers" {
  description = "Logical consumer names. One bucket per consumer; bucket name is cluster_name plus a dash plus the consumer name. Order is stable so adding a consumer at the end never re-creates earlier buckets."
  type        = list(string)
  default     = ["tofu-state", "etcd-snapshots", "longhorn-backups"]

  validation {
    condition     = length(var.consumers) == length(toset(var.consumers))
    error_message = "consumers must contain unique values; duplicates would cause two resources with the same name."
  }
}

variable "etcd_snapshot_retention_days" {
  description = "Lifecycle policy: delete etcd-snapshot objects older than this many days. RKE2 itself enforces a snapshot-count retention via `etcd-snapshot-retention`; this lifecycle rule is a backstop. Default 7d aligns with the assumption that cluster destroy/rebuild beats snapshot restore at the tooling we have."
  type        = number
  default     = 7
}

variable "longhorn_backup_retention_days" {
  description = "Lifecycle policy: delete longhorn-backup objects older than this many days. Longhorn's own backup-retention (per-volume) handles in-app cleanup; this lifecycle rule is a backstop. Default 30d for application data."
  type        = number
  default     = 30
}
