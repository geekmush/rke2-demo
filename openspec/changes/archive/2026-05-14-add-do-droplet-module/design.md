# Design — add-do-droplet-module

**Tracking issue:** [#1](https://github.com/geekmush/rke2-demo/issues/1)

## Module boundary and parameterization

A reusable **child module** lives at `terraform/modules/do-droplet-infra/`. A **root environment** at `terraform/environments/do-test/` consumes it. This split lets the Phase 4 bare-metal work introduce a sibling module `terraform/modules/bm-node-infra/` with the **same output shape**, so the Ansible inventory generator that consumes these outputs in a later change does not need to know which provider produced the nodes (groundrule #3 — Ansible-handoffable, provider-pluggable).

Inputs are intentionally provider-agnostic where they can be:

| Input | Type | Notes |
|---|---|---|
| `project_name` | string | tag prefix for all resources |
| `region` | string | DO region slug, e.g. `nyc3` |
| `vpc_cidr` | string | `/20` recommended |
| `cp_count` | number | default 3 |
| `cp_size` | string | default `s-2vcpu-4gb` |
| `worker_count` | number | default 3 |
| `worker_size` | string | default `s-4vcpu-8gb` |
| `image_slug` | string | default `ubuntu-24-04-x64` |
| `ssh_pubkey` | string | OpenSSH public key — passed by root caller, not read from `~/.ssh` |
| `allowed_ssh_cidrs` | list(string) | default `["0.0.0.0/0", "::/0"]` per access model |
| `tags` | list(string) | extra tags to merge onto every resource |

The DO API token is **not** a module input — it's a provider-level secret, set in the root `providers.tf` from a root-level variable.

## File layout

```
terraform/
├── README.md
├── Makefile                            # sops-aware wrappers: plan, apply, destroy, fmt
├── modules/
│   └── do-droplet-infra/
│       ├── versions.tf                 # tofu + DO provider pins
│       ├── variables.tf
│       ├── outputs.tf
│       ├── vpc.tf
│       ├── ssh_key.tf
│       ├── firewall.tf
│       ├── droplets.tf
│       ├── project.tf                  # optional DO Project attachment
│       └── cloud-init.yaml.tftpl
└── environments/
    └── do-test/
        ├── versions.tf
        ├── providers.tf
        ├── main.tf                     # module "infra" { source = "../../modules/..." }
        ├── variables.tf
        ├── outputs.tf
        ├── secrets.enc.tfvars          # SOPS — DO token only
        └── terraform.tfvars.example    # non-secret defaults, committed
```

## Firewall rules (access model)

Inbound, applied to all six droplets via a single `digitalocean_firewall` resource. Outbound: allow all (default).

| Proto | Port    | Source              | Purpose                              |
|-------|---------|---------------------|--------------------------------------|
| TCP   | 22      | `allowed_ssh_cidrs` | SSH — key-only, enforced in sshd too |
| TCP   | 6443    | VPC CIDR            | kube-apiserver                       |
| TCP   | 9345    | VPC CIDR            | RKE2 supervisor                      |
| TCP   | 10250   | VPC CIDR            | kubelet                              |
| TCP   | 2379-2380 | VPC CIDR          | etcd                                 |
| UDP   | 8472    | VPC CIDR            | flannel VXLAN (default CNI)          |
| ICMP  | —       | VPC CIDR            | ping inside VPC                      |

Rules are built from a `local.cluster_ports` list so the same set can be reused by the bare-metal module later. The default-CNI assumption (flannel VXLAN on 8472) is documented in `firewall.tf` next to the rule — if we switch CNI in a later change, that rule moves with it.

## Cloud-init

`cloud-init.yaml.tftpl` is **minimal and idempotent** so an Ansible role can re-run anything it does without harm (groundrule #3):

- `swapoff -a` and remove the swap line from `/etc/fstab`
- `/etc/modules-load.d/k8s.conf` loading `br_netfilter` and `overlay`
- `/etc/sysctl.d/99-k8s.conf` with:
  - `net.bridge.bridge-nf-call-iptables = 1`
  - `net.bridge.bridge-nf-call-ip6tables = 1`
  - `net.ipv4.ip_forward = 1`
  - `sysctl --system` reload
- `sshd_config` hardening:
  - `PasswordAuthentication no`
  - `PermitRootLogin prohibit-password`
  - `KbdInteractiveAuthentication no`
  - restart sshd
- **No package installs beyond what cloud-init already brings.** No RKE2, no Docker, no curl-piping installers. Anything past OS prereqs belongs in an Ansible role.

The template renders with one variable: `hostname` (so each droplet's user_data shows its own name in logs). Everything else is static.

## DigitalOcean Project attachment (optional)

The DO Project (called `RKE2` in the test environment) is **managed out-of-band** in the DO web UI, not by Tofu. The module looks it up via `data "digitalocean_project"` and attaches droplet URNs to it via `digitalocean_project_resources`. Rationale:

- Avoids `tofu import` dance for a resource that already exists.
- Keeps project lifecycle out of `tofu destroy` — destroying the test env empties the project but leaves the container.
- Only droplets are attached. DO Projects do not group VPCs or firewalls; those associate with the droplets implicitly in the UI.

If `do_project_name` is `null`, the data source and attachment resource both have `count = 0` and the feature is a no-op. The API token therefore only needs `project:read` + `project:update` when project attachment is in use. The default is `"RKE2"`; flip to `null` to skip.

## Secrets handling (groundrule #9)

The DO API token enters Tofu via `terraform/environments/do-test/secrets.enc.tfvars`, encrypted with SOPS+age per `.sops.yaml`. The encrypted file is committed; the decrypted form never touches disk in a tracked path.

**Operator flow (pattern (a) — locked in):**

```bash
# Wrapped by `make plan` in terraform/Makefile:
TMP=$(mktemp --suffix=.tfvars)
trap 'rm -f "$TMP"' EXIT
sops --decrypt terraform/environments/do-test/secrets.enc.tfvars > "$TMP"
tofu -chdir=terraform/environments/do-test plan -var-file="$TMP"
```

Why pattern (a) over `carlpett/sops` Tofu provider:

| | Pattern (a) shell-wrapper | Pattern (b) carlpett/sops provider |
|---|---|---|
| Plaintext on disk | Temp file, removed on shell exit | Never on disk, only in provider memory |
| Extra dependency | sops only (already installed) | Non-core Tofu provider, pinned + cached |
| State implications | None | Decrypted values can land in state if referenced naively |
| Failure mode if absent | Plan fails fast at decrypt step | Plan fails at provider init |
| Reversibility | Trivial — delete the wrapper | Need to remove the provider, refactor refs |

(a) is simpler and reversible. We can revisit (b) if the shell wrapper becomes load-bearing.

`.gitignore` already excludes `*.tfvars` and `*.env`. Verify during implementation that `*.tfvars.example` is **not** excluded (so `terraform.tfvars.example` can be committed) and `*.enc.tfvars` is explicitly allowed (the SOPS-encrypted ones must be committed).

## State backend

**Local state on this pass.** `terraform.tfstate` and `terraform.tfstate.backup` are operator-local and `.gitignore`'d (already covered by the existing `.gitignore`). A follow-up issue (to be filed after this one merges) tracks moving to DO Spaces remote state.

Why deferred:

- Remote state backend on DO Spaces has its own chicken-and-egg: the Spaces bucket itself needs to be provisioned somewhere — either by Tofu (recursive) or by hand (manual step we don't want).
- For a 6-node test environment with one operator, local state is acceptable short-term — destroying and recreating costs minutes, not hours.
- Risk is contained: nothing in this change is "production data."

The follow-up issue will weigh DO Spaces vs Terraform Cloud vs an S3-compatible backend hosted on the cluster itself (once Longhorn lands).

## Outputs — shaped for Ansible hand-off

The module exports:

```hcl
output "cp_nodes" {
  # list(object({ name, public_ip, private_ip, id }))
}
output "worker_nodes" {
  # same shape
}
output "vpc_id"              { ... }
output "vpc_cidr"            { ... }
output "firewall_id"         { ... }
output "ssh_key_fingerprint" { ... }
output "region"              { ... }
```

The root `do-test` environment re-exports these unchanged. A later change will render them into an Ansible inventory (likely via `tofu output -json | jq` or `community.general.terraform_state` inventory plugin) — but **no inventory rendering happens here**, only the contract.

## Version pins

- `tofu` ≥ 1.8.0
- `digitalocean/digitalocean` provider — pin to current minor (TBD at implementation time; check registry at impl)
- Cloud-init `user_data` uses the default cloud-init shipped with `ubuntu-24-04-x64`; no version pin needed.

## Risks / things to revisit

- **Default CNI assumption (flannel VXLAN).** Hardcoded port 8472 in the firewall. If RKE2 default changes or we pick Cilium later, the rule needs updating. Documented next to the rule in `firewall.tf`.
- **`s-2vcpu-4gb` for control plane is on the edge** of upstream RKE2 minimum recommendations. Acceptable for a test environment; flag in the runbook so a Phase 4 reviewer revisits sizing for bare metal.
- **Six droplets at the listed sizes** is real money on DO (~$190/mo at list price if always-on). The runbook calls out `make destroy` between sessions so this is opex-managed.
- **SSH key fingerprint drift.** If the operator rotates SSH keys, the `digitalocean_ssh_key` resource recreates and droplets keep the old key embedded in cloud-init. Out-of-band rotation procedure goes in the runbook.

## Hand-off contract to the next change

The next change after this one merges is expected to be either:

1. `add-rke2-ansible-role` — installs RKE2 on the droplets via Ansible, consuming this module's outputs as the inventory source, **or**
2. `add-tofu-remote-state` — moves state to DO Spaces (small, gated by the chicken-and-egg call above).

Either way: this change must not bake any assumptions into the module that those follow-ups have to undo.
