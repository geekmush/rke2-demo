# Tasks — add-do-droplet-module

**Tracking issue:** [#1](https://github.com/geekmush/rke2-demo/issues/1)

Implementation order. Each task is small enough to be a discrete commit. Check off as completed in the PR.

## Scaffolding

- [x] 1. Create directory skeleton: `terraform/modules/do-droplet-infra/` and `terraform/environments/do-test/`.
- [x] 2. Write `terraform/modules/do-droplet-infra/versions.tf` — pin `tofu` ≥ 1.8 and `digitalocean/digitalocean` provider to current minor.
- [x] 3. Write `terraform/environments/do-test/versions.tf` — same pins.

## Module — inputs/outputs first

- [x] 4. `modules/do-droplet-infra/variables.tf` — every input from the table in `design.md`, with types and defaults.
- [x] 5. `modules/do-droplet-infra/outputs.tf` — `cp_nodes`, `worker_nodes`, `vpc_id`, `vpc_cidr`, `firewall_id`, `ssh_key_fingerprint`, `region`, in the exact shape called out in `design.md` (object-of-fields lists).

## Module — resources

- [x] 6. `modules/do-droplet-infra/vpc.tf` — `digitalocean_vpc.main`, region- and CIDR-parameterized.
- [x] 7. `modules/do-droplet-infra/ssh_key.tf` — `digitalocean_ssh_key.operator` from `var.ssh_pubkey`. Compute and export fingerprint.
- [x] 8. `modules/do-droplet-infra/firewall.tf` — single `digitalocean_firewall.cluster` covering the rule table in `design.md`. Build inbound rules from a `local.cluster_ports` list so the bare-metal module can reuse it later. Default egress: allow all.
- [x] 9. `modules/do-droplet-infra/cloud-init.yaml.tftpl` — swap off, kernel modules, sysctls, sshd hardening. One template variable: `hostname`. Idempotent.
- [x] 10. `modules/do-droplet-infra/droplets.tf` — `digitalocean_droplet.cp` (count `var.cp_count`) and `digitalocean_droplet.worker` (count `var.worker_count`), each VPC-attached, firewall-attached, with `user_data = templatefile("...", { hostname = ... })` and the SSH key bound.
- [x] 10a. `modules/do-droplet-infra/project.tf` — optional `data "digitalocean_project"` + `digitalocean_project_resources` attaching droplet URNs to an existing DO Project. Gated on `var.do_project_name != null`. Default in env: `"RKE2"`.

## Root environment

- [x] 11. `environments/do-test/providers.tf` — DO provider configured from `var.do_token`.
- [x] 12. `environments/do-test/variables.tf` — declare `do_token` (sensitive), `ssh_pubkey`, `allowed_ssh_cidrs`, `region`, and any sizing overrides we want to expose.
- [x] 13. `environments/do-test/main.tf` — `module "infra" { source = "../../modules/do-droplet-infra" ... }`.
- [x] 14. `environments/do-test/outputs.tf` — re-export the module outputs.
- [x] 15. `environments/do-test/terraform.tfvars.example` — non-secret defaults, committed. Includes a placeholder `ssh_pubkey` and a comment about generating one if needed.

## Secrets

- [x] 16. Verify `.gitignore` excludes `*.tfvars` but allows `*.tfvars.example` and `*.enc.tfvars`. Adjust if needed.
- [x] 17. Author `secrets.enc.tfvars` correctly from the start: write a plaintext draft to `/tmp/`, encrypt with `sops --encrypt --in-place` after copying into the repo path, **never** create a plaintext version inside the working tree. Confirm `ENC[AES256_GCM,...]` blobs after encrypt.
- [x] 18. Confirm `.sops.yaml` `path_regex` matches `*.enc.tfvars` (it does — `\.enc\.(ya?ml|json|env|tfvars)$`).

## Operator wrapper

- [x] 19. `terraform/Makefile` with targets: `init`, `fmt`, `validate`, `plan`, `apply`, `destroy`, `output`. Each that needs the DO token wraps `sops -d` → temp tfvars → `tofu` → cleanup via `trap`.
- [x] 20. Verify `make plan` runs the full flow end-to-end on a clean shell with the SOPS keyring present, and that the temp tfvars is removed even when `tofu plan` fails.

## Docs (groundrule #7)

- [x] 21. `docs/runbooks/do-bring-up.md` — preconditions, prereqs, secret hand-off, `make plan` / `make apply` flow, post-apply verification (SSH in, confirm swap off, confirm modules loaded), `make destroy` between sessions.
- [x] 22. `docs/diagrams/do-network.md` — Mermaid showing the VPC, the firewall posture (public SSH, VPC-internal everything else), control-plane and worker droplet placement, and the operator's path in (SSH from internet, kube API via tunnel later).
- [x] 23. `terraform/README.md` — module/env layout pointer + link to the runbook.
- [x] 24. Update top-level `README.md` "Getting started" to link `docs/runbooks/do-bring-up.md`.

## Validation (no apply on this pass)

- [x] 25. `cd terraform/environments/do-test && tofu fmt -check -recursive` clean.
- [x] 26. `make init` clean.
- [x] 27. `make validate` clean — no warnings.
- [x] 28. `make plan` produces a plan with the expected resource counts: 1 VPC, 1 SSH key, 1 firewall, 6 droplets. No unexpected deprecation warnings.
- [x] 29. Verify `git status` shows no plaintext tfvars, no `terraform.tfstate*`, no decrypted secret artifacts.

## Close-out

- [ ] 30. Open PR. Title: `Add OpenTofu module for DigitalOcean droplet infra (closes #1)`. Body references `openspec/changes/add-do-droplet-module/` and includes the `make plan` output as a collapsed block.
- [x] 31. Walk the secrets safe-staging checklist from `docs/runbooks/secrets.md` before requesting review.
- [ ] 32. Merge. Issue #1 closes automatically via the PR keyword.
- [ ] 33. File the follow-up issue: "Move DO test env to remote state (DO Spaces)" — milestone Phase 1, labels `type:task, phase-1, area:tofu, priority:normal`.
- [ ] 34. Move this change directory: `openspec/changes/add-do-droplet-module/` → `openspec/changes/archive/<date>-add-do-droplet-module/` per OpenSpec workflow.
