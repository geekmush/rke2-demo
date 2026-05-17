locals {
  # Inter-node RKE2 ports (VPC-internal only).
  # Kept as a list so the Phase 4 bare-metal module can reuse the exact same set.
  # Default CNI assumption: flannel VXLAN on UDP/8472. If the CNI changes, the
  # corresponding rule moves with it.
  cluster_tcp_ports = [
    { port = "6443", purpose = "kube-apiserver" },
    { port = "9345", purpose = "rke2-supervisor" },
    { port = "10250", purpose = "kubelet" },
    { port = "2379-2380", purpose = "etcd-client-and-peer" },
  ]

  cluster_udp_ports = [
    { port = "8472", purpose = "flannel-vxlan" },
  ]
}

resource "digitalocean_firewall" "cluster" {
  name = "${var.project_name}-cluster"

  droplet_ids = concat(
    digitalocean_droplet.cp[*].id,
    digitalocean_droplet.worker[*].id,
  )

  # SSH — public reachability per CLAUDE.md access model. Key-only is enforced
  # in sshd_config by cloud-init; this firewall rule only controls L3/L4 reach.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = var.allowed_ssh_cidrs
  }

  # RKE2 inter-node TCP — VPC-internal only.
  dynamic "inbound_rule" {
    for_each = local.cluster_tcp_ports
    content {
      protocol         = "tcp"
      port_range       = inbound_rule.value.port
      source_addresses = [var.vpc_ip_range]
    }
  }

  # RKE2 inter-node UDP — VPC-internal only.
  dynamic "inbound_rule" {
    for_each = local.cluster_udp_ports
    content {
      protocol         = "udp"
      port_range       = inbound_rule.value.port
      source_addresses = [var.vpc_ip_range]
    }
  }

  # ICMP inside the VPC — useful for ping/MTR during debugging.
  inbound_rule {
    protocol         = "icmp"
    source_addresses = [var.vpc_ip_range]
  }

  # Kubernetes NodePort range — open to the world so DigitalOcean's REGIONAL
  # Load Balancers can forward to backends. Test #4 on 2026-05-17 discovered
  # that the LB sources backend traffic from outside the VPC's CIDR, so the
  # cluster_tcp_ports VPC-only rule above does NOT cover the LB->NodePort path.
  # Without this rule, ingress-nginx Service of type LoadBalancer accepts TCP
  # at the LB IP but resets every TLS handshake (LB sees backends as
  # unreachable and never forwards). See issue #41.
  #
  # Risk profile: NodePorts are kubelet-allocated on Service create and
  # rotate when Services are recreated. The only Service of type LoadBalancer
  # in this cluster is ingress-nginx, which IS intentionally a public path.
  # Anyone reaching a NodePort directly via a worker's public IP gets routed
  # to the same backend they'd reach via the LB -- no additional exposure
  # beyond what the LB already provides. For a production-phase tightening,
  # narrow source_addresses to DO's published LB source range (see DO docs
  # at https://docs.digitalocean.com/products/networking/load-balancers/details/limits/).
  inbound_rule {
    protocol         = "tcp"
    port_range       = "30000-32767"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # Egress — allow all. We are not trying to be a perimeter firewall here;
  # the goal is to constrain inbound exposure.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
