# Internal (VPC-only) load balancer in front of the 3 control-plane droplets.
#
# Two forwarding rules:
#   - tcp/6443  -> tcp/6443   (kube-apiserver)
#   - tcp/9345  -> tcp/9345   (RKE2 supervisor)
#
# Healthcheck probes tcp/9345 because the RKE2 supervisor starts before
# kube-apiserver during boot, so it gates the LB earlier in cluster
# bring-up.
#
# This is `network = "INTERNAL"` deliberately: the LB has no public IP and
# is reachable only from inside the VPC. That keeps groundrule "RKE2
# inter-node ports: VPC-internal only" intact (no droplet firewall
# loosening required) and avoids the DO LB source-IP-preservation problem
# that breaks the EXTERNAL-LB-with-firewall-ACL approach.
#
# Operator access pre-Twingate: SSH-tunnel from the workstation through
# any healthy CP to this LB's VPC IP -- see ansible/scripts/kube-tunnel.sh.
# Operator access post-Twingate: connector inside the VPC routes traffic
# to this LB directly.
#
# Application/ingress LB (HTTP/HTTPS for cluster apps) is a separate
# resource introduced in Phase 3 by FluxCD; this LB is for cluster
# control plane only.

resource "digitalocean_loadbalancer" "cp" {
  name     = "${var.project_name}-cp"
  region   = var.region
  size     = "lb-small"
  network  = "INTERNAL"
  vpc_uuid = var.vpc_id

  droplet_ids = digitalocean_droplet.cp[*].id

  forwarding_rule {
    entry_protocol  = "tcp"
    entry_port      = 6443
    target_protocol = "tcp"
    target_port     = 6443
  }

  forwarding_rule {
    entry_protocol  = "tcp"
    entry_port      = 9345
    target_protocol = "tcp"
    target_port     = 9345
  }

  healthcheck {
    protocol = "tcp"
    port     = 9345
  }
}
