output "cp_nodes" {
  description = "Control-plane droplets. Shape: list(object({ name, public_ip, private_ip, id }))."
  value = [
    for d in digitalocean_droplet.cp : {
      name       = d.name
      public_ip  = d.ipv4_address
      private_ip = d.ipv4_address_private
      id         = d.id
    }
  ]
}

output "worker_nodes" {
  description = "Worker droplets. Same shape as cp_nodes — a later change renders these into an Ansible inventory."
  value = [
    for d in digitalocean_droplet.worker : {
      name       = d.name
      public_ip  = d.ipv4_address
      private_ip = d.ipv4_address_private
      id         = d.id
    }
  ]
}

output "firewall_id" {
  description = "DigitalOcean firewall UUID."
  value       = digitalocean_firewall.cluster.id
}

output "ssh_key_fingerprint" {
  description = "Fingerprint of the SSH key registered with DigitalOcean."
  value       = digitalocean_ssh_key.operator.fingerprint
}

output "region" {
  description = "DigitalOcean region slug used for this deployment."
  value       = var.region
}

output "cp_endpoint" {
  description = "Public IP of the control-plane load balancer. RKE2 join URL is https://<cp_endpoint>:9345; kube API is https://<cp_endpoint>:6443. RKE2 tls-san accepts IPs."
  value       = digitalocean_loadbalancer.cp.ip
}

output "worker_longhorn_devices" {
  description = "Map of worker hostname -> stable Longhorn block-device path (DO by-id; survives reboot device-name shuffle). Consumed by the FluxCD-managed Longhorn install in Phase 3."
  value = {
    for i, d in digitalocean_droplet.worker :
    d.name => "/dev/disk/by-id/scsi-0DO_Volume_${digitalocean_volume.longhorn[i].name}"
  }
}
