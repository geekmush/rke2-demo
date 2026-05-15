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
  value       = module.infra.vpc_id
}

output "vpc_cidr" {
  description = "VPC IP range."
  value       = module.infra.vpc_cidr
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
