locals {
  base_tags = concat(
    [var.project_name, "rke2"],
    var.tags,
  )
}

resource "digitalocean_droplet" "cp" {
  count = var.cp_count

  name     = format("%s-cp-%02d", var.project_name, count.index + 1)
  region   = var.region
  size     = var.cp_size
  image    = var.image_slug
  vpc_uuid = var.vpc_id

  ssh_keys = [digitalocean_ssh_key.operator.fingerprint]

  monitoring = true
  ipv6       = false

  tags = concat(local.base_tags, ["role:control-plane"])

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      hostname = format("%s-cp-%02d", var.project_name, count.index + 1)
    },
  )
}

resource "digitalocean_droplet" "worker" {
  count = var.worker_count

  name     = format("%s-worker-%02d", var.project_name, count.index + 1)
  region   = var.region
  size     = var.worker_size
  image    = var.image_slug
  vpc_uuid = var.vpc_id

  ssh_keys = [digitalocean_ssh_key.operator.fingerprint]

  monitoring = true
  ipv6       = false

  tags = concat(local.base_tags, ["role:worker"])

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      hostname = format("%s-worker-%02d", var.project_name, count.index + 1)
    },
  )
}
