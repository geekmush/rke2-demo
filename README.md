# rke2-demo

RKE2 + Longhorn cluster bring-up. Test phase on DigitalOcean, production phase on bare metal. Platform components and cluster apps managed via FluxCD using [devopscoop's fluxcd-template](https://github.com/devopscoop/fluxcd-template) (vendored as a git subtree). Cluster operations via `k9s` / OpenLens on the operator workstation.

> **Status:** skeleton only. No OpenTofu or Ansible code yet.

## Why this repo exists

devopscoop's templates cover FluxCD-managed cluster apps but do not yet ship an RKE2 deployment path. This repo builds that path — first as a working DO test environment, then as a reusable, bare-metal-capable contribution back upstream.

## Phases

| Phase | Target | Storage | Notes |
| --- | --- | --- | --- |
| 1 — Bring-up | 3 CP + 3 worker droplets on DO | none (deferred) | First end-to-end RKE2 install via Ansible |
| 2 — Storage substrate | Same droplets + dedicated DO Block Storage volumes | volumes attached, not yet formatted by Longhorn | Stages disks Longhorn will claim once FluxCD installs it |
| 3 — GitOps | Same | Longhorn installed by FluxCD | FluxCD vendored as subtree; manages cert-manager, ingress-nginx, external-dns, Longhorn, and the rest of the apps stack |
| 4 — Production | Bare metal | dedicated disks | Same modules/roles, different provider |
| 5 — Upstream | n/a | n/a | Contribute RKE2 parts to devopscoop |

## Toolchain

- **OpenTofu** — IaC under [`terraform/`](terraform/)
- **Ansible** — config management under [`ansible/`](ansible/)
- **uv** — Python environment and script runner
- **OpenSpec** — change proposals and specs under `openspec/`
- **SOPS + age** — secrets encryption; rules in [`.sops.yaml`](.sops.yaml). Encrypted files use the `*.enc.<ext>` convention. No plaintext secrets in git, ever.
- **FluxCD** — end-state app delivery (downstream of this repo)

## Work tracking

- **GitHub Issues** on `geekmush/rke2-demo` — backlog, bugs, milestones.
- **OpenSpec** under `openspec/changes/<name>/` — per-change proposals, design, tasks; each links to its tracking Issue.
- Production environment uses **Gitea**, which is GitHub-import compatible — anything filed here is portable.

## Layout

```
.
├── CLAUDE.md           # operating rules for Claude Code — read first
├── README.md
├── terraform/          # OpenTofu modules and root configs
├── ansible/            # roles, playbooks, inventory
├── docs/
│   ├── runbooks/       # operational procedures
│   └── diagrams/       # Mermaid sources
└── openspec/           # OpenSpec proposals and specs
```

## Access model (test phase)

- SSH (22): public, **key-only** — no passwords, no root password login.
- Kubernetes API (6443): VPC-internal only — reach it via SSH tunnel or the Rancher UI.
- RKE2 inter-node traffic: DO VPC private network.

## Getting started

Phase 1 substrate (VPC + firewall + SSH key + 6 droplets + cloud-init) is provisioned with the OpenTofu module under [`terraform/modules/do-droplet-infra/`](terraform/modules/do-droplet-infra/), consumed by the root env at [`terraform/environments/do-test/`](terraform/environments/do-test/). RKE2 is installed on that substrate via Ansible (3 CP HA + 3 workers).

End-to-end operator procedure:
1. [`docs/runbooks/do-bring-up.md`](docs/runbooks/do-bring-up.md) — droplets, VPC, firewall, internal CP load balancer.
2. [`docs/runbooks/rke2-install.md`](docs/runbooks/rke2-install.md) — RKE2 server + agent install, kubeconfig retrieval, operator SSH tunnel.

Network topology: [`docs/diagrams/do-network.md`](docs/diagrams/do-network.md).
RKE2 cluster topology: [`docs/diagrams/rke2-topology.md`](docs/diagrams/rke2-topology.md).

Rancher, Longhorn, and FluxCD land in subsequent changes.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for the seven groundrules. Non-trivial changes go through an OpenSpec proposal under `openspec/`.
