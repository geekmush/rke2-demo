# do-nyc3-rke2-demo

RKE2 + Longhorn cluster bring-up. Test phase on DigitalOcean, production phase on bare metal. Platform components and cluster apps managed via FluxCD using [devopscoop's fluxcd-template](https://github.com/devopscoop/fluxcd-template) (vendored as a git subtree). Cluster operations via `k9s` / OpenLens on the operator workstation.

> **Status:** Phase 1 (RKE2 cluster on DigitalOcean) and Phase 2 (per-worker Block Storage volumes for Longhorn) complete. Phase 3 (FluxCD-managed apps) in progress -- platform components (cert-manager, ingress-nginx, external-dns, DO CCM) reconciled; Longhorn enablement (Phase 3c) is the active workstream.

## Why this repo exists

devopscoop's templates cover FluxCD-managed cluster apps but do not yet ship an RKE2 deployment path. This repo builds that path — first as a working DO test environment, then as a reusable, bare-metal-capable contribution back upstream.

## Phases

| Phase | Target | Storage | Notes |
| --- | --- | --- | --- |
| 1 — Bring-up | 3 CP + 3 worker droplets on DO | none (deferred) | First end-to-end RKE2 install via Ansible |
| 2 — Storage substrate | Same droplets + dedicated DO Block Storage volumes | volumes attached, not yet formatted by Longhorn | Stages disks Longhorn will claim once FluxCD installs it |
| 3 — GitOps | Same | Longhorn V1 filesystem-mode (ext4 on dedicated DO volumes at `/var/lib/longhorn`); hard-isolated from OS disk via opt-in node labels. Phase 3d (in progress) adds DO Spaces buckets for Tofu remote state, RKE2 etcd snapshots, Longhorn backup target. | FluxCD vendored as subtree; manages cert-manager, ingress-nginx, external-dns, DO CCM, Longhorn, and the rest of the apps stack |
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

- **GitHub Issues** on `geekmush/do-nyc3-rke2-demo` — backlog, bugs, milestones.
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
1. [`docs/runbooks/do-bring-up.md`](docs/runbooks/do-bring-up.md) — droplets, VPC, firewall, internal CP load balancer, Phase 2 Block Storage volumes.
2. [`docs/runbooks/rke2-install.md`](docs/runbooks/rke2-install.md) — RKE2 server + agent install, Longhorn disk prep (mkfs + mount + node label/annotate), kubeconfig retrieval, operator SSH tunnel.
3. [`docs/runbooks/fluxcd-bootstrap.md`](docs/runbooks/fluxcd-bootstrap.md) — `flux bootstrap` + first reconcile of the platform components.
4. [`docs/runbooks/install-do-ccm.md`](docs/runbooks/install-do-ccm.md) — DigitalOcean Cloud Controller Manager (LoadBalancer Service support).
5. [`docs/runbooks/longhorn-enablement.md`](docs/runbooks/longhorn-enablement.md) — Phase 3c Longhorn enablement, verify, rollback.
6. [`docs/runbooks/s3-object-store-enablement.md`](docs/runbooks/s3-object-store-enablement.md) — Phase 3d DO Spaces buckets (Tofu state, etcd snapshots, Longhorn backups); designed for Phase 4 swap to Wasabi.

When something goes sideways: [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) — symptom-indexed reference from the bring-up validation arc.

Diagrams: [`docs/diagrams/do-network.md`](docs/diagrams/do-network.md), [`docs/diagrams/rke2-topology.md`](docs/diagrams/rke2-topology.md), [`docs/diagrams/public-traffic-path.md`](docs/diagrams/public-traffic-path.md), [`docs/diagrams/longhorn-topology.md`](docs/diagrams/longhorn-topology.md), [`docs/diagrams/s3-object-store-topology.md`](docs/diagrams/s3-object-store-topology.md), [`docs/diagrams/dns-migration.md`](docs/diagrams/dns-migration.md).

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for the seven groundrules. Non-trivial changes go through an OpenSpec proposal under `openspec/`.
