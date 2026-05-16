variable "project_name" {
  description = "Short prefix applied to resource names and tags. e.g. \"rke2-demo\"."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug. Must support VPC, firewalls, and the chosen droplet sizes. e.g. \"nyc3\", \"sfo3\"."
  type        = string
}

variable "vpc_id" {
  description = "UUID of the DigitalOcean VPC to place every droplet and the internal LB into. Created and owned at the environment level (see terraform/environments/<env>/vpc.tf) — the module never creates or destroys VPCs because DO refuses to delete the regional default VPC, which makes a module-owned VPC poison the destroy plan."
  type        = string
}

variable "vpc_ip_range" {
  description = "CIDR of the VPC referenced by var.vpc_id. Needed inside the module for firewall rules that allow VPC-internal traffic. Same source as var.vpc_id."
  type        = string
}

variable "image_slug" {
  description = "DigitalOcean image slug used for every droplet."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "cp_count" {
  description = "Number of control-plane droplets."
  type        = number
  default     = 3
}

variable "cp_size" {
  description = "Droplet size slug for control-plane nodes."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_count" {
  description = "Number of worker droplets."
  type        = number
  default     = 3
}

variable "worker_size" {
  description = "Droplet size slug for worker nodes."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "ssh_pubkey" {
  description = "OpenSSH-format public key string (e.g. \"ssh-ed25519 AAAA... operator@host\"). Passed by the root caller — not read from disk inside the module."
  type        = string

  validation {
    condition     = can(regex("^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)) ", var.ssh_pubkey))
    error_message = "ssh_pubkey must be an OpenSSH-format public key (starts with ssh-ed25519, ssh-rsa, or ecdsa-sha2-nistpNNN)."
  }
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks permitted to reach TCP/22. SSH is key-only regardless (sshd hardened in cloud-init), but you can still narrow this. Default matches CLAUDE.md access model: world-reachable, key-only."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "tags" {
  description = "Extra tags applied to every droplet, alongside the module-managed role tags."
  type        = list(string)
  default     = []
}

variable "do_project_name" {
  description = "Name of an existing DigitalOcean Project to attach the droplets to (looked up by name). Set to null to skip project attachment. Requires project:read and project:update on the API token."
  type        = string
  default     = null
}

variable "longhorn_volume_size_gb" {
  description = "Size (GB) of each per-worker DigitalOcean Block Storage volume staged for Longhorn. One volume per worker; volumes are attached but left raw (no filesystem) so Longhorn can claim them in block-device mode in Phase 3."
  type        = number
  default     = 50

  validation {
    condition     = var.longhorn_volume_size_gb >= 1 && var.longhorn_volume_size_gb <= 16384
    error_message = "longhorn_volume_size_gb must be between 1 and 16384 (DO Block Storage limits)."
  }
}
