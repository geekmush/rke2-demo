# The VPC lives at the environment level (not inside the do-droplet-infra
# module) for one practical reason: DigitalOcean designates exactly one VPC
# per region as the "default" and refuses to delete it via API. The first
# VPC we created in nyc3 became that default. `tofu destroy` then hangs for
# ~2 minutes before failing with `403: Can not delete default VPCs`, which
# made `make destroy` exit non-zero even when every other resource was torn
# down cleanly. (See issue #26.)
#
# Solution: hoist the VPC out of the destroy-able module and declare it here
# with prevent_destroy. Module resources (droplets, LB, firewall, volumes)
# still come and go on every apply/destroy cycle; the VPC stays put.
#
# Day-2 workflow:
#   make apply                              # creates VPC on first apply, no-ops thereafter
#   make destroy                            # tofu destroy -target='module.infra' (see Makefile)
#                                           # destroys everything except this VPC; exits 0 cleanly
#
# Initial state migration (one-shot, only if you're upgrading from the
# pre-#26 layout where the VPC was inside the module):
#   tofu -chdir=environments/do-test state mv \
#     module.infra.digitalocean_vpc.main \
#     digitalocean_vpc.this
#
# After the migration, `tofu plan` should report no changes for the VPC.
resource "digitalocean_vpc" "this" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = var.vpc_cidr

  lifecycle {
    prevent_destroy = true
  }
}
