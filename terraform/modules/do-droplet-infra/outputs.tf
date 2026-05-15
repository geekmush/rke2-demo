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

output "vpc_id" {
  description = "DigitalOcean VPC UUID."
  value       = digitalocean_vpc.main.id
}

output "vpc_cidr" {
  description = "VPC IP range as configured."
  value       = digitalocean_vpc.main.ip_range
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
