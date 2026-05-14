# rke2-demo

RKE2 + Rancher + Longhorn cluster bring-up. Test phase on DigitalOcean, production phase on bare metal. Cluster apps managed via FluxCD using [devopscoop's fluxcd-template](https://github.com/devopscoop).

> **Status:** skeleton only. No OpenTofu or Ansible code yet.

## Why this repo exists

devopscoop's templates cover FluxCD-managed cluster apps but do not yet ship an RKE2 deployment path. This repo builds that path — first as a working DO test environment, then as a reusable, bare-metal-capable contribution back upstream.

## Phases

| Phase | Target | Storage | Notes |
| --- | --- | --- | --- |
| 1 — Bring-up | 3 CP + 3 worker droplets on DO | none (deferred) | First end-to-end RKE2 + Rancher install |
| 2 — Storage | Same droplets | DO Block Storage, dedicated per node | Longhorn enabled, separate disks mandatory |
| 3 — GitOps | Same | same | FluxCD with devopscoop template manages apps |
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

Nothing to run yet. Next milestone: an OpenTofu module for DO droplets — VPC, firewall, SSH key resource, and minimal cloud-init (swap off, kernel modules, sysctls). RKE2 install lands in a later pass.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for the seven groundrules. Non-trivial changes go through an OpenSpec proposal under `openspec/`.
