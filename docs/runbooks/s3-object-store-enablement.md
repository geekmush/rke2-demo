# S3-compatible object-store enablement — operator runbook

Provision DigitalOcean Spaces buckets (Phase 3 test) or Wasabi buckets (Phase 4 prod) for three consumers that all speak S3: Tofu remote state, RKE2 etcd snapshots, Longhorn backup target. Designed for the provider swap to be `.tfvars` + SOPS-encrypted credentials only, no code fork.

> **Scope of THIS PR (substrate, PR 1).** This runbook covers Phase 3 DO Spaces bucket provisioning and the operator workflow for creating the Spaces access key. Per-consumer enablement (Tofu state migration PR 2, etcd snapshots PR 3, Longhorn backup target PR 4) is documented in the per-PR sections below — each section is empty until that PR lands.

## Prerequisites

- Phase 1 / Phase 2 substrate already provisioned (the spaces module rides on the same Tofu env at `terraform/environments/do-test/`).
- Operator workstation has `tofu`, `sops`, `age` already configured per [`secrets.md`](secrets.md).
- DigitalOcean account billing covers Spaces ($5/mo base for the first 250 GiB + $0.02/GiB/mo over, $0.01/GiB egress over the 1 TiB included).

## One-time setup — Spaces access key

The Spaces access key is **operator-created in the DO control panel**, NOT Tofu-managed. Rationale: rotating a Tofu-managed credential implies a `tofu apply` that itself uses the credential to authenticate — chicken-and-egg.

1. DO control panel → API → Spaces Keys → **Generate New Key**.
2. Name suggestion: `do-nyc3-rke2-demo-spaces-key`. Note both the access key ID and the secret (the secret is shown once only).
3. Add the keys to the env's encrypted `.tfvars`:
   ```bash
   sops terraform/environments/do-test/secrets.enc.tfvars
   # Add:
   #   object_store_access_key = "DO00ABC123..."
   #   object_store_secret_key = "...long secret..."
   # Save + exit; sops re-encrypts on exit.
   ```
4. Verify the variable values are reachable (don't print to terminal; just confirm sops re-encryption succeeded):
   ```bash
   sops -d terraform/environments/do-test/secrets.enc.tfvars | grep -c object_store_access_key
   # Expect: 1
   ```

## Phase 3 — provision DO Spaces buckets

```bash
make -C terraform plan         # confirm the 3 bucket resources show in the plan
make -C terraform apply        # creates the buckets
make -C terraform output object_store_buckets
# {
#   "etcd-snapshots"    = "do-nyc3-rke2-demo-etcd-snapshots"
#   "longhorn-backups"  = "do-nyc3-rke2-demo-longhorn-backups"
#   "tofu-state"        = "do-nyc3-rke2-demo-tofu-state"
# }
make -C terraform output object_store_endpoint
# "https://nyc3.digitaloceanspaces.com"
```

The default consumer set is `[tofu-state, etcd-snapshots, longhorn-backups]`. To skip a consumer (e.g. you don't want Longhorn backups yet), set `consumers` explicitly in the env's `terraform.tfvars` or pass on the command line.

### What gets created

| Bucket | Versioning | Lifecycle | force_destroy |
|---|---|---|---|
| `do-nyc3-rke2-demo-tofu-state` | enabled | none — keep all versions indefinitely | **false** (operator protection) |
| `do-nyc3-rke2-demo-etcd-snapshots` | disabled | expire after `etcd_snapshot_retention_days` (default 7) | true |
| `do-nyc3-rke2-demo-longhorn-backups` | disabled | expire after `longhorn_backup_retention_days` (default 30) | true |

### Verify post-apply

```bash
# Each bucket visible in DO control panel under Spaces.
# Each bucket has the expected lifecycle rule (Spaces UI → bucket → Settings → Lifecycle).
# Versioning enabled on tofu-state only:
curl -sS -X GET \
  -u "$(sops -d terraform/environments/do-test/secrets.enc.tfvars | grep object_store_access_key | sed -E 's/.*"([^"]+)".*/\1/'):$(sops -d terraform/environments/do-test/secrets.enc.tfvars | grep object_store_secret_key | sed -E 's/.*"([^"]+)".*/\1/')" \
  --aws-sigv4 'aws:amz:us-east-1:s3' \
  "https://do-nyc3-rke2-demo-tofu-state.nyc3.digitaloceanspaces.com/?versioning"
# Expect: <VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>
```

## Per-consumer enablement (filled in by subsequent PRs)

### PR 2 — Tofu remote state migration

*To be added when PR 2 lands.* Will cover: `backend.tf` shape, `tofu init -migrate-state` sequence, rollback if migration fails, post-migration `tofu plan` no-diff check.

### PR 3 — RKE2 etcd snapshots

*To be added when PR 3 lands.* Will cover: Ansible group_vars credentials handoff from `secrets.enc.tfvars` → `ansible/inventory/group_vars/all/secrets.yaml`, expected `config.yaml` shape on a CP, `journalctl -u rke2-server` validation, listing snapshots in the bucket.

### PR 4 — Longhorn backup target

*To be added when PR 4 lands.* Will cover: `apps/longhorn/backup-target.secrets.yaml` shape, `BackupTarget` CR availability check, end-to-end backup + restore test.

## Cost notes

DO Spaces pricing (list 2026):
- $5/mo base = 250 GiB storage + 1 TiB egress included
- $0.02/GiB/mo over 250 GiB
- $0.01/GiB egress over 1 TiB

For this cluster's expected usage (Tofu state <1 MiB, etcd snapshots ~10-50 MiB × ~28 = ~1 GiB, Longhorn backups depend on workload):
- Storage cost ≈ $5/mo flat
- Egress cost ≈ $0 (the included 1 TiB is plenty for snapshot + state R/W)

DO Spaces persists across `make destroy` of droplets (the spaces module is independent of `module.infra`). Manual `make destroy` of the env would attempt to destroy the buckets too — `force_destroy = false` on `tofu-state` will refuse if there's any state in the bucket; `etcd-snapshots` + `longhorn-backups` destroy cleanly with their `force_destroy = true`.

## Phase 4 swap to Wasabi

When the operator is ready to move to Hivelocity (Phase 4):

1. Author `terraform/modules/wasabi/` with the same outputs (`buckets`, `endpoint`, `region`, `bucket_urns`). Likely uses the AWS Tofu provider with `endpoint` override pointed at Wasabi.
2. Change `object_store_provider = "wasabi"` in the env's `.tfvars`.
3. Re-encrypt `secrets.enc.tfvars` with the Wasabi access key.
4. Re-encrypt `ansible/inventory/group_vars/all/secrets.yaml` (PR 3 onward) with the same Wasabi credentials for etcd-s3 + Longhorn.
5. `tofu init -migrate-state` again — moves Tofu state from DO Spaces to Wasabi.
6. Everything else (Ansible role, Longhorn values template, runbook procedure) unchanged.

Phase 4 gotchas to plan for:
- **Wasabi 90-day minimum storage charge per object** — don't churn etcd snapshots faster than that unless you accept the cost shape.
- **Wasabi free egress within tier** — Longhorn backup restore from Wasabi is free; DO Spaces would bill egress past 1 TiB.
- **Wasabi bucket creation** typically operator-managed in their console rather than via Tofu (depending on Wasabi's API parity). The Wasabi module either creates buckets or accepts existing names as a var.

## See also

- [`openspec/changes/enable-s3-object-store/proposal.md`](../../openspec/changes/enable-s3-object-store/proposal.md) — why + decisions + success criteria.
- [`openspec/changes/enable-s3-object-store/design.md`](../../openspec/changes/enable-s3-object-store/design.md) — provider abstraction + per-bucket policy + chicken-and-egg.
- [`docs/diagrams/s3-object-store-topology.md`](../diagrams/s3-object-store-topology.md) — who writes to which bucket.
- [`docs/TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — symptom-indexed reference (includes an S3 section).
- [`docs/runbooks/secrets.md`](secrets.md) — SOPS workflow.
- [`docs/runbooks/do-bring-up.md`](do-bring-up.md) — Phase 2 substrate (the spaces module sits alongside it).
