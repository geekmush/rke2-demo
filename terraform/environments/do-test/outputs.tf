output "cp_nodes" {
  description = "Control-plane droplets."
  value       = module.infra.cp_nodes
}

output "worker_nodes" {
  description = "Worker droplets."
  value       = module.infra.worker_nodes
}

output "vpc_id" {
  description = "DigitalOcean VPC UUID."
  value       = digitalocean_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC IP range."
  value       = digitalocean_vpc.this.ip_range
}

output "firewall_id" {
  description = "Firewall UUID."
  value       = module.infra.firewall_id
}

output "ssh_key_fingerprint" {
  description = "DigitalOcean SSH key fingerprint."
  value       = module.infra.ssh_key_fingerprint
}

output "region" {
  description = "Region slug."
  value       = module.infra.region
}

output "cp_endpoint" {
  description = "Control-plane load balancer IP. kube API at https://<cp_endpoint>:6443; RKE2 supervisor at https://<cp_endpoint>:9345."
  value       = module.infra.cp_endpoint
}

output "worker_longhorn_devices" {
  description = "Map of worker hostname -> stable Longhorn block-device path. Consumed by the FluxCD-managed Longhorn install in Phase 3."
  value       = module.infra.worker_longhorn_devices
}

# --- S3-compatible object store outputs ---
# Map and individual-bucket forms both surfaced: the map shape is what
# render-inventory.py consumes; the per-bucket forms are convenient for
# operator-level grep / shell scripting.

output "object_store_buckets" {
  description = "Map of consumer name -> bucket name. Populated when object_store_provider creates a module. Empty when disabled."
  value       = length(module.spaces) > 0 ? module.spaces[0].buckets : {}
}

output "tofu_state_bucket" {
  description = "Bucket name for Tofu remote state. Used by terraform/environments/do-test/backend.tf (added in PR 2)."
  value       = length(module.spaces) > 0 ? module.spaces[0].buckets["tofu-state"] : null
}

output "etcd_snapshot_bucket" {
  description = "Bucket name for RKE2 etcd snapshots. Consumed by Ansible group_vars via render-inventory.py."
  value       = length(module.spaces) > 0 ? module.spaces[0].buckets["etcd-snapshots"] : null
}

output "longhorn_backup_bucket" {
  description = "Bucket name for Longhorn volume backups. Consumed by apps/longhorn/values.yaml (PR 4) + the Secret apps/longhorn/backup-target.secrets.yaml."
  value       = length(module.spaces) > 0 ? module.spaces[0].buckets["longhorn-backups"] : null
}

output "object_store_endpoint" {
  description = "S3-compatible endpoint URL. e.g. \"https://nyc3.digitaloceanspaces.com\" for DO Spaces. Consumed everywhere that talks S3: Tofu backend, RKE2 etcd-s3, Longhorn backup target."
  value       = length(module.spaces) > 0 ? module.spaces[0].endpoint : null
}

output "object_store_region" {
  description = "Region slug the object-store buckets live in. Same as var.object_store_region; surfaced for downstream consumers."
  value       = length(module.spaces) > 0 ? module.spaces[0].region : null
}
