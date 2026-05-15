# CLAUDE.md — rke2-demo

Operating instructions for Claude Code in this repository. Read this before doing any non-trivial work.

## Project goal

Stand up an RKE2 + Longhorn cluster — first on DigitalOcean droplets (test phase), then on bare metal (production phase). End-state cluster apps (including the platform components: cert-manager, ingress-nginx, external-dns, Longhorn, etc.) are managed via FluxCD using [devopscoop's fluxcd-template](https://github.com/devopscoop/fluxcd-template), vendored as a git subtree into this repo. Cluster operations use `k9s` / OpenLens on the operator workstation. Rancher is **deliberately out of scope** at this phase — revisit only if multi-cluster management materializes in Phase 4+. RKE2 deployment artifacts produced here are intended to be contributed back to devopscoop (no RKE2 repo exists there yet — this would be a net-new contribution).

## Test-phase infrastructure (DigitalOcean)

- 3× `s-2vcpu-4gb` droplets — control plane
- 3× `s-4vcpu-8gb` droplets — workers
- Inter-node RKE2 traffic over a DO VPC private network
- Longhorn storage: skipped on the very first pass; **Block Storage volumes are required** before Longhorn is enabled (test phase 2). No `hostpath`-on-root shortcuts.

## Production phase

Bare metal. Modules and Ansible roles must be parameterized so the same code targets either provider without forking.

## The groundrules — do not deviate without explicit user approval

1. **Python via `uv`.** Never `pip install` directly. Use `uv` for envs, deps, and script execution.
2. **OpenTofu (not Terraform)** for IaC. All `.tf` files live under `terraform/`.
3. **Ansible-maintainable deploys.** Even when bootstrapping by hand, structure work so an Ansible role can take over without rewriting. Avoid one-shot imperative scripts that can't be expressed declaratively.
4. **Separate disks for Longhorn.** Skipped on the first test pass only. From test phase 2 onward, Longhorn always runs on dedicated DO Block Storage volumes (or dedicated disks on bare metal). Never colocate Longhorn data with the OS disk in any state we plan to keep.
5. **End-state app management via FluxCD using devopscoop's fluxcd-template.** Cluster apps are GitOps, not `kubectl apply`. The RKE2 bring-up work here is the substrate that template runs on top of — and the RKE2 parts should be contributed back upstream.
6. **AI-assist framework: OpenSpec.** Chosen over BMAD as lighter-weight, infra-friendly, and composable with GitOps. Spec changes go through `openspec/` proposals before implementation.
7. **Docs are mandatory, not optional.** Every meaningful change ships with: updated `README.md`, updated `CLAUDE.md` if rules change, a runbook under `docs/runbooks/` if it introduces an operational procedure, and a Mermaid diagram under `docs/diagrams/` for any new architecture or process flow.
8. **No AI attribution in git history or GitHub.** Commit messages, PR titles/bodies, issue comments, and review comments must not include `Co-Authored-By: Claude`, "Generated with Claude Code", or any other AI agent attribution, footer, or trailer. Author the work as the human committer.
9. **Secrets via SOPS — never in cleartext.** Secrets are encrypted with [SOPS](https://github.com/getsops/sops) using **age** keys and live in the repo as `*.enc.yaml` / `*.enc.json` / `*.enc.env` files colocated with what they configure (e.g. `terraform/secrets.enc.tfvars`, `ansible/group_vars/all/secrets.enc.yaml`). Encryption rules are declared in `.sops.yaml` at the repo root. **Never commit a plaintext secret, token, private key, kubeconfig, or `.tfvars` containing sensitive values.** Decryption keys (`~/.config/sops/age/keys.txt` or equivalent) are operator-local and never enter git. Work-tracking note: GitHub Issues are the active backlog here; Gitea import (used in production) is GitHub-compatible.

## Access model (test phase)

- **SSH (22):** open to `0.0.0.0/0`, **key-only**. No password auth, no root password login. Firewall + `sshd_config` must both enforce this.
- **Kubernetes API (6443):** VPC-internal only. Operators reach it via SSH tunnel or the Rancher UI — never exposed publicly.
- **RKE2 inter-node ports:** VPC-internal only.
- Anything that loosens this needs an explicit user decision recorded in a runbook.

## Repository layout

```
.
├── CLAUDE.md              # this file
├── README.md              # human-facing overview
├── terraform/             # OpenTofu modules and root configs
├── ansible/               # roles, playbooks, inventory
├── docs/
│   ├── runbooks/          # operational procedures
│   └── diagrams/          # Mermaid sources
└── openspec/              # OpenSpec proposals and specs
```

## Workflow expectations

- Use OpenSpec proposals for non-trivial changes (new modules, new roles, scope shifts).
- Prefer editing existing files over creating new ones.
- When introducing a new tool or pattern, document the choice and the alternative considered.
- Secrets never land in git. `.gitignore` already covers `*.tfvars`, `*.env`, key material — verify before staging.
