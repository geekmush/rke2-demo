# Optional attachment to an existing DigitalOcean Project.
#
# Project existence is managed out-of-band (in the DO web UI) — this module
# only slots resources into it. If var.do_project_name is null, this block
# is a no-op.
#
# Note: only droplets are attached. DigitalOcean Projects group droplets,
# load balancers, volumes, floating IPs, etc. — but NOT VPCs or firewalls
# (those associate with droplets implicitly).
#
# Token scope requirement: project:read + project:update.

data "digitalocean_project" "this" {
  count = var.do_project_name != null ? 1 : 0
  name  = var.do_project_name
}

resource "digitalocean_project_resources" "this" {
  count   = var.do_project_name != null ? 1 : 0
  project = data.digitalocean_project.this[0].id

  resources = concat(
    digitalocean_droplet.cp[*].urn,
    digitalocean_droplet.worker[*].urn,
  )
}
