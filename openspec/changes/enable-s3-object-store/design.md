# Design — enable-s3-object-store

## File layout (delta from main, post-merge of all 4 PRs)

```
terraform/
├── modules/
│   ├── do-droplet-infra/                       # unchanged
│   └── do-spaces/                              # NEW (PR 1)
│       ├── main.tf                             # buckets + lifecycle + versioning
│       ├── variables.tf
│       └── outputs.tf
└── environments/do-test/
    ├── main.tf                                 # adds module "spaces"
    ├── outputs.tf                              # adds tofu_state_bucket etc.
    ├── variables.tf                            # adds object_store_* vars
    ├── backend.tf                              # NEW (PR 2 — switches to s3)
    └── secrets.enc.tfvars                      # +AWS_ACCESS_KEY_ID, +AWS_SECRET_ACCESS_KEY

ansible/
├── inventory/group_vars/all/
│   ├── main.yml                                # +etcd_snapshot_bucket etc. (rendered)
│   └── secrets.yaml                            # +etcd_s3_access_key, +etcd_s3_secret_key
├── roles/rke2_server/
│   └── templates/config.yaml.j2                # +etcd-s3 block (PR 3)
└── scripts/render-inventory.py                 # emit object_store_* into group_vars (PR 1)

apps/longhorn/
├── values.yaml                                 # real backupTarget + secret name (PR 4)
├── backup-target.secrets.yaml                  # NEW SOPS-encrypted Secret (PR 4)
└── kustomization.yaml                          # re-add secretGenerator for backup target (PR 4)

docs/
├── runbooks/
│   └── s3-object-store-enablement.md           # NEW (PR 1)
├── diagrams/
│   └── s3-object-store-topology.md             # NEW (PR 1)
├── runbooks/do-bring-up.md                     # Phase 2 prereq note (PR 1)
└── TROUBLESHOOTING.md                          # S3 section (PR 1 stub, expanded per PR)
```

## Provider abstraction shape

The umbrella decision is *where* to put the variability. Three reasonable places:

| Where | Pro | Con | Decision |
|---|---|---|---|
| Per-consumer (Tofu state has DO knobs, etcd has Wasabi knobs, etc.) | Each consumer config self-contained | 3× duplication, drifts | ❌ |
| Per-provider module with a uniform interface | Single var surface across consumers | Initial complexity | ✅ |
| Per-environment .tfvars only, hardcoded provider in modules | Simplest | Phase-4 needs a fork — violates CLAUDE.md #3 | ❌ |

Choosing **per-provider module with uniform interface**:

```hcl
# Phase 3 (this change)
module "spaces" {
  source       = "../../modules/do-spaces"
  cluster_name = var.cluster_name
  region       = var.object_store_region
  buckets      = ["tofu_state", "etcd_snapshots", "longhorn_backups"]
}

# Phase 4 (future, stubbed only)
# module "wasabi" {
#   source       = "../../modules/wasabi"
#   cluster_name = var.cluster_name
#   region       = var.object_store_region
#   buckets      = ["tofu_state", "etcd_snapshots", "longhorn_backups"]
# }
```

Both modules expose the **same outputs**: `tofu_state_bucket`, `etcd_snapshot_bucket`, `longhorn_backup_bucket`, `endpoint`, `region`, `access_key_id` (sensitive), `secret_access_key` (sensitive). Consumers (Ansible inventory render, Longhorn HelmRelease, Tofu backend block) read those outputs without knowing which provider produced them.

`object_store_provider` var (default `do_spaces`) selects which module the root env consumes. Initially only `do_spaces` instantiated; Phase 4 wires up `wasabi` symmetrically.

## Per-bucket policy table

| Bucket | Versioning | Lifecycle | Operator override |
|---|---|---|---|
| `${cluster}-tofu-state` | **enabled** (state recovery is high-stakes) | none (keep all versions — state files are kilobytes) | `prevent_destroy = true` on the bucket resource |
| `${cluster}-etcd-snapshots` | disabled | delete-after-7d (default, var: `etcd_snapshot_retention_days = 7`) | adjust the var |
| `${cluster}-longhorn-backups` | disabled | delete-after-30d (default, var: `longhorn_backup_retention_days = 30`) | adjust the var |

DO Spaces lifecycle = a `digitalocean_spaces_bucket_policy` + `lifecycle_rule` block. Wasabi equivalent = the same protocol; both providers honor S3 lifecycle rules.

## Chicken-and-egg: Tofu state migration

The bucket holding the Tofu state file is itself in the state. PR 2 sequence:

1. **PR 1 already merged** — `do-spaces` module + `module "spaces"` block is in main. `tofu apply` has created the buckets using the *local* state.
2. PR 2 introduces `terraform/environments/do-test/backend.tf`:
   ```hcl
   terraform { backend "s3" { ... } }
   ```
3. Operator runs `tofu init -migrate-state` — Tofu reads the local state, writes it to the new S3 backend, prompts confirmation, removes the local file.
4. PR 2 committed AFTER step 3 succeeds locally. (The `backend.tf` is committed but the local `terraform.tfstate` was already gone post-migration.)
5. All subsequent `tofu apply` reads/writes state via S3 with DynamoDB-free locking (DO Spaces supports it; Wasabi too — see `use_lockfile = true` in the backend block, which uses object-store atomic-put for locking rather than a separate locking service).

Rollback if step 3 fails: revert `backend.tf`, restore `terraform.tfstate` from operator's local backup, re-`tofu init`.

## etcd snapshot config plumbing

RKE2 reads `/etc/rancher/rke2/config.yaml` at startup. The `rke2_server` role's template gets a new conditional block:

```jinja
{% if etcd_snapshot_s3_enabled | default(false) %}
etcd-s3: true
etcd-s3-endpoint: "{{ etcd_snapshot_s3_endpoint }}"
etcd-s3-bucket: "{{ etcd_snapshot_s3_bucket }}"
etcd-s3-region: "{{ etcd_snapshot_s3_region }}"
etcd-s3-access-key: "{{ etcd_snapshot_s3_access_key }}"
etcd-s3-secret-key: "{{ etcd_snapshot_s3_secret_key }}"
etcd-snapshot-schedule-cron: "{{ etcd_snapshot_schedule | default('0 */6 * * *') }}"
etcd-snapshot-retention: {{ etcd_snapshot_retention | default(28) }}
{% endif %}
```

Variables come from `render-inventory.py` (which already emits Tofu outputs into group_vars). The credentials come from `ansible/inventory/group_vars/all/secrets.yaml` (SOPS-encrypted).

**Snapshot location naming**: RKE2 names snapshots `etcd-snapshot-${node-name}-${unix-timestamp}` by default. Bucket prefix unset → snapshots in the bucket root. Listing them: `aws s3 ls s3://${cluster}-etcd-snapshots/ --endpoint-url=${endpoint}`.

## Longhorn backup target

Two pieces:

1. **`apps/longhorn/values.yaml`** — replace the upstream `evanstest` placeholder:
   ```yaml
   defaultBackupStore:
     backupTarget: "s3://${cluster}-longhorn-backups@${region}/"   # templated
     backupTargetCredentialSecret: longhorn-backup-target
     pollInterval: 300
   ```
2. **`apps/longhorn/backup-target.secrets.yaml`** — new SOPS-encrypted Secret:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: longhorn-backup-target
     namespace: longhorn-system
   stringData:
     AWS_ACCESS_KEY_ID: "..."
     AWS_SECRET_ACCESS_KEY: "..."
     AWS_ENDPOINTS: "https://nyc3.digitaloceanspaces.com"
   ```
3. **`apps/longhorn/kustomization.yaml`** — re-add `secretGenerator` (which we removed in `enable-longhorn` proposal v2 because we had no Helm-values secrets — now we do).

Longhorn polls the backup target every 300s; an unreachable target shows `available: false` in the BackupTarget CR.

## Alternatives considered and rejected

- **Use DynamoDB-style locking via a sidecar service.** Tofu's S3 backend now supports `use_lockfile = true` which uses atomic S3 PUT for locking. No sidecar needed. Saves a moving part.
- **Provision buckets in Ansible instead of Tofu.** Tofu owns infra; Ansible owns config. Bucket creation is infra. Also: Tofu provider for DO Spaces already exists; no Ansible Spaces collection of similar quality.
- **Share one bucket with prefixes (`tofu-state/`, `etcd/`, `longhorn/`).** Rejected — different retention policies are awkward with a shared bucket (lifecycle rules can scope to prefix, but blast radius of credential leak is bigger).
- **Per-consumer credentials.** Rejected for now — operator wants one rotation surface. Revisit if/when policy support warrants.
- **Manually-created buckets, no Tofu involvement.** Rejected — drifts immediately; bucket name + region + lifecycle policy need to be authoritative somewhere. Tofu is that somewhere.
- **Skip Phase 4 abstraction now and just hardcode DO.** Rejected — CLAUDE.md groundrule #3 mandates portability. Adding the abstraction now is cheap; adding it later means rewriting both consumers and the module.

## Hand-off contract to Phase 4

For the operator who eventually swaps DO Spaces for Wasabi:

- Author `terraform/modules/wasabi/` with the same outputs (`tofu_state_bucket`, `etcd_snapshot_bucket`, `longhorn_backup_bucket`, `endpoint`, `region`, `access_key_id`, `secret_access_key`). Module body is provider-specific (likely `aws` provider pointed at Wasabi endpoint, since Wasabi doesn't have a first-class Tofu provider — uses the AWS provider with `endpoint` override).
- Change `object_store_provider = "wasabi"` in the env's `.tfvars`.
- Re-encrypt `secrets.enc.tfvars` with the Wasabi access key.
- Re-encrypt `ansible/inventory/group_vars/all/secrets.yaml` with the Wasabi credentials for etcd-s3 + Longhorn.
- `tofu init -migrate-state` again (or `terraform state mv` between backends).
- Everything else — Ansible role, Longhorn values template, runbook procedure — is unchanged.

Phase-4 gotchas (already in proposal):
- Wasabi 90-day minimum storage charge per object → don't churn etcd snapshots faster than 90d unless you're OK with the cost shape.
- Wasabi free egress within tier → Longhorn backup restore from Wasabi is free; DO Spaces would bill egress past 1 TB.
- Wasabi bucket creation: typically operator-managed in their console rather than the AWS Tofu provider, depending on Wasabi's API parity. Module abstracts this.
