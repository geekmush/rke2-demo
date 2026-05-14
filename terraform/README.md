# terraform/

OpenTofu modules and root configurations for the rke2-demo cluster substrate.

> OpenTofu, not Terraform — per groundrule #2 in [`../CLAUDE.md`](../CLAUDE.md).

## Layout

```
terraform/
├── Makefile                              # sops-aware wrappers for plan/apply/destroy/etc.
├── modules/
│   └── do-droplet-infra/                 # DigitalOcean substrate: VPC, firewall, SSH key,
│                                         #   droplets, cloud-init, optional project attach
└── environments/
    └── do-test/                          # Phase 1 root config that consumes the module
        ├── secrets.enc.tfvars            # SOPS-encrypted DO API token (operator-created)
        └── terraform.tfvars.example      # non-secret defaults
```

## Operator workflow

End-to-end procedure lives in [`../docs/runbooks/do-bring-up.md`](../docs/runbooks/do-bring-up.md).

TL;DR:

```bash
cd terraform
make init
make plan
make apply
make destroy   # when you're done for the day
```

`make plan` / `apply` / `destroy` wrap `sops -d` so the DO API token is decrypted to a `mktemp` file, used, and removed via `trap` — no plaintext lingers in the working tree or shell history.

## Adding a new environment

Mirror `environments/do-test/`:

1. Copy the directory.
2. Update `versions.tf` if you want different pins.
3. Update `terraform.tfvars.example` and (if applicable) `secrets.enc.tfvars`.
4. Add a `make`-target group or a wrapper script if the new env needs different secrets handling.

## Adding a new module

Mirror `modules/do-droplet-infra/`:

- Keep variables provider-agnostic in shape where possible — the Phase 4 bare-metal module should be drop-in for the DO module from any caller's perspective.
- Outputs must match the contract documented in
  [`../openspec/changes/add-do-droplet-module/design.md`](../openspec/changes/add-do-droplet-module/design.md)
  if the module produces nodes that an Ansible inventory will consume.

## State

Local state on this pass. `terraform.tfstate` is `.gitignore`d. Remote state (DO Spaces) is tracked as a follow-up issue.
