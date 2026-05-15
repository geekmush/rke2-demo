variable "do_token" {
  description = "DigitalOcean Personal Access Token. Supplied from SOPS-decrypted secrets.enc.tfvars via the Makefile wrapper — never plaintext on disk."
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Resource-name prefix."
  type        = string
  default     = "rke2-demo"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "nyc3"
}

variable "vpc_cidr" {
  description = "Private CIDR for the VPC."
  type        = string
  # The VPC range overlaps RKE2's default pod CIDR (10.42.0.0/16). To avoid
  # the CNI's pod-network routes shadowing the VPC routes inside the kernel
  # routing table, the RKE2 server role pins cluster-cidr and service-cidr
  # to non-overlapping ranges (10.244.0.0/16 / 10.245.0.0/16) -- see
  # ansible/inventory/group_vars/all/main.yml.
  #
  # Why not just move the VPC? DO marks one VPC per region as "default" and
  # refuses both deletion and demotion of it. This VPC is currently nyc3's
  # default, so changing its CIDR (a ForceNew on the resource) is blocked.
  default = "10.42.0.0/20"
}

variable "ssh_pubkey" {
  description = "OpenSSH public-key string for the operator. Public keys are not sensitive — supplied via terraform.tfvars, not SOPS."
  type        = string
}

variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed to reach TCP/22. Default is world (key-only is enforced in sshd_config)."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "cp_count" {
  description = "Override control-plane droplet count."
  type        = number
  default     = 3
}

variable "cp_size" {
  description = "Override control-plane droplet size slug."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_count" {
  description = "Override worker droplet count."
  type        = number
  default     = 3
}

variable "worker_size" {
  description = "Override worker droplet size slug."
  type        = string
  default     = "s-4vcpu-8gb"
}

variable "image_slug" {
  description = "Override DigitalOcean image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "tags" {
  description = "Extra tags applied to every droplet."
  type        = list(string)
  default     = []
}

variable "do_project_name" {
  description = "Existing DigitalOcean Project to attach droplets to. Set to null to skip. Default matches the manually-created \"RKE2\" project."
  type        = string
  default     = "RKE2"
}

