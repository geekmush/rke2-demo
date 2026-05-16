module "infra" {
  source = "../../modules/do-droplet-infra"

  project_name      = var.project_name
  region            = var.region
  vpc_id            = digitalocean_vpc.this.id
  vpc_ip_range      = digitalocean_vpc.this.ip_range
  ssh_pubkey        = var.ssh_pubkey
  allowed_ssh_cidrs = var.allowed_ssh_cidrs

  cp_count     = var.cp_count
  cp_size      = var.cp_size
  worker_count = var.worker_count
  worker_size  = var.worker_size

  image_slug      = var.image_slug
  tags            = var.tags
  do_project_name = var.do_project_name
}
