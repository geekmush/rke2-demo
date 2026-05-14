# Proposal — add-do-droplet-module

**Tracking issue:** [#1](https://github.com/geekmush/rke2-demo/issues/1)
**Phase:** 1 — DO bring-up
**Status:** proposed

## Why

Phase 1 needs the DigitalOcean substrate before RKE2 can land. Per CLAUDE.md, all IaC is OpenTofu under `terraform/`, structured so an Ansible role can take over later without rewriting (groundrule #3), with the DO API token handled via SOPS (groundrule #9) and the full docs set updated (groundrule #7). This change ships exactly that substrate — and stops short of RKE2 install, which lands in a follow-up change.

This is also the first tracked work item end-to-end (Issue + OpenSpec + PR), so it sets the working pattern for everything that follows in this repo.

## What this change ships

- **Reusable child module** `terraform/modules/do-droplet-infra/`
  - `digitalocean_vpc` with a parameterized CIDR
  - `digitalocean_ssh_key` from a public-key input
  - `digitalocean_firewall` implementing the access model (table in `design.md`)
  - `digitalocean_droplet` resources — 3× `s-2vcpu-4gb` control plane + 3× `s-4vcpu-8gb` workers, VPC-attached, firewall-attached, with templated cloud-init `user_data`
  - `cloud-init.yaml.tftpl` doing only OS prereqs: swap off, kernel modules (`br_netfilter`, `overlay`), sysctls, sshd hardening (`PasswordAuthentication no`, `PermitRootLogin prohibit-password`)
- **Root environment** `terraform/environments/do-test/`
  - Consumes the module
  - SOPS-encrypted `secrets.enc.tfvars` carrying only the DO API token
  - `terraform.tfvars.example` documenting non-secret inputs
- **Operator wrapper** — `terraform/Makefile` (or `justfile`) target wrapping `sops -d` → temp tfvars → `tofu <cmd>` → cleanup, so plaintext token never lingers on disk and never lands in shell history.
- **Docs**
  - `docs/runbooks/do-bring-up.md` — end-to-end operator procedure
  - `docs/diagrams/do-network.md` — Mermaid showing VPC, firewall posture, droplet placement
  - `terraform/README.md` — module/env layout pointer
  - `README.md` "Getting started" updated to link the runbook

## Out of scope (explicit non-goals)

- No RKE2 install, no Rancher, no Longhorn — those are separate changes.
- No Block Storage volumes — Longhorn is deferred to Phase 2 per groundrule #4.
- No remote state backend on this pass. Local state only; a follow-up issue tracks moving to DO Spaces remote state once the chicken-and-egg bootstrap is decided.
- No Ansible role yet. Module outputs are *shaped* to feed an Ansible inventory in the next change, but no inventory rendering or role lands here.
- `tofu apply` is **not** part of this change's exit criteria. First apply happens in a follow-up issue once the plan has been reviewed.

## Decisions locked in (from review on 2026-05-14)

1. Droplet resources ship together with VPC/firewall/SSH-key/cloud-init in this single change — the cloud-init template only earns its keep once attached to a droplet.
2. **SOPS pattern (a)**: shell-wrapper `sops -d` → tmp tfvars → `tofu <cmd>` → cleanup. No `carlpett/sops` Tofu provider on this pass; can revisit if friction emerges.
3. OpenSpec change hand-authored (no `/opsx:propose` skill on this one — infra-shape changes have been easier to draft directly, and there is no parent spec yet for the skill to amend).
4. Local Tofu state on this pass; remote state deferred to a follow-up issue.
5. OpenSpec change directory uses a **semantic** name, not the issue id — preserves portability for the Phase 5 upstream contribution to devopscoop. Issue id is recorded in this file's header instead.

## Success criteria

- `tofu init && tofu fmt -check && tofu validate && tofu plan` all succeed on a clean checkout, against decrypted tfvars, with no warnings about deprecated provider arguments.
- `git diff` on the PR contains zero plaintext secrets. Every secret-bearing file is `*.enc.<ext>` and shows `ENC[AES256_GCM,...]` blobs.
- Firewall rules in code match the access-model table in `design.md` exactly — SSH 22 public, everything else VPC-internal.
- Docs updated per groundrule #7: `README.md`, runbook, Mermaid diagram.
- PR is reviewable end-to-end without consulting external context: design and tasks live in this directory.
