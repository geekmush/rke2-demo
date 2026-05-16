# DigitalOcean network topology — Phase 1

Logical view of the substrate provisioned by `terraform/modules/do-droplet-infra/`. RKE2 is **not** installed yet — this diagram shows what exists after a successful `make apply` of Phase 1.

## Topology

```mermaid
flowchart TB
    operator(["Operator workstation<br/>(SSH client)"])
    internet{{Internet}}

    operator -->|"TCP/22<br/>key-only"| fw_ssh

    subgraph do["DigitalOcean account"]
        subgraph project["Project: RKE2"]
            subgraph vpc["VPC — 10.42.0.0/20 (private)"]
                subgraph cp["Control plane (3× s-2vcpu-4gb)"]
                    cp1["do-nyc3-rke2-demo-cp-01"]
                    cp2["do-nyc3-rke2-demo-cp-02"]
                    cp3["do-nyc3-rke2-demo-cp-03"]
                end
                subgraph wk["Workers (3× s-4vcpu-8gb)"]
                    wk1["do-nyc3-rke2-demo-worker-01"]
                    wk2["do-nyc3-rke2-demo-worker-02"]
                    wk3["do-nyc3-rke2-demo-worker-03"]
                end
            end
        end

        fw_ssh["Firewall rule:<br/>TCP/22 from 0.0.0.0/0"]
        fw_int["Firewall rules (VPC-internal only):<br/>TCP 6443, 9345, 10250, 2379-2380<br/>UDP 8472<br/>ICMP"]

        fw_ssh -.applies to.-> cp
        fw_ssh -.applies to.-> wk
        fw_int -.applies to.-> cp
        fw_int -.applies to.-> wk
    end

    cp1 <-->|"VPC traffic"| cp2
    cp2 <-->|"VPC traffic"| cp3
    cp1 <-->|"VPC traffic"| cp3
    cp <-->|"VPC traffic"| wk

    internet -.->|"6443 — BLOCKED at firewall"| vpc
    operator -->|"future: SSH tunnel<br/>localhost:6443 → VPC"| cp1
```

## Reachability summary

| Source                    | Destination                  | Port            | Allowed?            |
|---------------------------|------------------------------|-----------------|---------------------|
| Public internet           | Any droplet                  | TCP/22 (SSH)    | ✅ key-only          |
| Public internet           | Any droplet                  | TCP/6443 (API)  | ❌ blocked           |
| Public internet           | Any droplet                  | Any other       | ❌ blocked           |
| Droplet inside VPC        | Droplet inside VPC           | TCP 6443        | ✅                   |
| Droplet inside VPC        | Droplet inside VPC           | TCP 9345        | ✅                   |
| Droplet inside VPC        | Droplet inside VPC           | TCP 10250       | ✅                   |
| Droplet inside VPC        | Droplet inside VPC           | TCP 2379-2380   | ✅                   |
| Droplet inside VPC        | Droplet inside VPC           | UDP 8472        | ✅ (flannel VXLAN)   |
| Droplet inside VPC        | Droplet inside VPC           | ICMP            | ✅                   |
| Operator → kube API       | TCP/6443                     |                 | only via SSH tunnel |

## Boot-time host setup (cloud-init)

Every droplet runs the same cloud-init template (`cloud-init.yaml.tftpl`) on first boot:

```mermaid
flowchart LR
    boot([First boot]) --> swap[swap off<br/>fstab edited]
    boot --> mods[modprobe<br/>br_netfilter, overlay]
    boot --> sysctl["sysctls:<br/>bridge-nf-call-iptables=1<br/>bridge-nf-call-ip6tables=1<br/>ip_forward=1"]
    boot --> ssh["sshd hardening:<br/>PasswordAuthentication no<br/>PermitRootLogin prohibit-password"]
    swap --> ready([RKE2-prereq ready])
    mods --> ready
    sysctl --> ready
    ssh --> ready
```

The template is intentionally minimal and idempotent so an Ansible role can replay any of these steps later without conflict.

## What's NOT here (yet)

- **RKE2** install — landed in a follow-up change.
- **Block Storage volumes** for Longhorn — Phase 2.
- **Ansible inventory** rendered from module outputs — follow-up change.
- **Remote state backend** (DO Spaces) — follow-up issue.
- **Load balancer / floating IPs** for the kube API — TBD; until then, operator access via SSH tunnel.
