# Proposal — enable-s3-object-store

**Tracking issue:** TBD (open at acceptance, label `phase-3, area:tofu, area:rke2, area:longhorn, priority:normal`).
**Phase:** 3d — S3-compatible object-store enablement (umbrella for #3, #8, deferred Longhorn backup target).
**Status:** draft 2026-05-18.

## Why

Three independent open items want the same substrate:

| Item | What it needs | Status |
|---|---|---|
| #3 (Tofu remote state) | A durable, lockable backend for `terraform.tfstate` outside the operator's laptop | Open, `phase-1, area:tofu, priority:normal` |
| #8 (etcd snapshots off-box) | A bucket RKE2 etcd-s3 can push snapshots to | Open, `phase-1, area:rke2, priority:normal` |
| Longhorn backup target | A bucket Longhorn can push volume backups to | Deferred from archived `enable-longhorn` proposal |

All three speak S3. Designing each one independently means three rounds of credential layout, three naming-convention bikesheds, three migration plans. One umbrella proposal locks the **provider abstraction** + **credential layout** + **bucket naming** once, then each consumer ships as its own focused PR against that substrate.

The abstraction is also load-bearing for Phase 4. Test phase = **DO Spaces** (operator already has billing + the DO Tofu provider already manages a Spaces resource type). Production phase = **Wasabi** (operator-chosen S3-compatible, runs in the Hivelocity environment). CLAUDE.md groundrule #3: "Modules and Ansible roles must be parameterized so the same code targets either provider without forking." That mandate applies here.

## What this change ships

### Tofu — provider abstraction + Phase-3 buckets

- New module `terraform/modules/do-spaces/` provisions 1 DO Spaces bucket per consumer (`tofu_state`, `etcd_snapshots`, `longhorn_backups`) with naming `${cluster_name}-${consumer}`. Each gets a versioning + lifecycle policy appropriate to its consumer (state retention long, snapshots 30d rolling, backups 90d rolling — operator-configurable).
- Root-env vars in `terraform/environments/do-test/`:
  - `object_store_provider` (`do_spaces` | `wasabi`) — selects which module the env consumes; only `do_spaces` implemented in this change, `wasabi` stubbed for Phase 4.
  - `object_store_region` (e.g. `nyc3`)
  - `object_store_endpoint` (e.g. `https://nyc3.digitaloceanspaces.com`) — derived from provider+region but overridable
  - `object_store_access_key` / `object_store_secret_key` — SOPS-encrypted in `secrets.enc.tfvars`
- New outputs: `tofu_state_bucket`, `etcd_snapshot_bucket`, `longhorn_backup_bucket`, `object_store_endpoint`, `object_store_region`. Consumed by Ansible inventory render + by the Tofu state-migration step itself.
- **Tofu state migration** to the new bucket: documented as a manual one-time operator step in the runbook (`tofu init -migrate-state` after writing the new `backend "s3"` block). Cannot be Tofu-managed end-to-end because of the chicken-and-egg (the bucket holding the state is itself in the state).

### Ansible — `rke2_server` etcd-s3 plumbing

- `ansible/roles/rke2_server/templates/config.yaml.j2`: add `etcd-s3: true`, `etcd-s3-endpoint`, `etcd-s3-bucket`, `etcd-s3-region`, `etcd-s3-access-key`, `etcd-s3-secret-key`, `etcd-snapshot-schedule-cron` (default `0 */6 * * *` = every 6h), `etcd-snapshot-retention` (default 28 = 7d at 6h cadence). All driven by group_vars.
- Credentials in `ansible/inventory/group_vars/all/secrets.yaml` (already SOPS-encrypted, this change adds the keys).
- Idempotent — a snapshot is taken on next RKE2 restart after config write.

### apps/longhorn — backup target wiring

- `apps/longhorn/values.yaml`: replace the upstream placeholder `defaultBackupStore.backupTarget: "s3://evanstest@us-west-1/"` + `backupTargetCredentialSecret: evanstest` with cluster-real values driven by the Helm release values template (cluster_name + endpoint).
- New `apps/longhorn/backup-target.secrets.yaml` — SOPS-encrypted Secret in `longhorn-system` namespace with `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS` keys per Longhorn doc.
- `apps/longhorn/kustomization.yaml`: re-introduce a `secretGenerator` for the backup-target Secret (the same pattern we removed in `enable-longhorn` proposal v2 because we had no Helm-values secrets — now we do).

### Docs

- `docs/runbooks/s3-object-store-enablement.md`: prereqs, bucket provisioning, Tofu state migration (chicken-and-egg sequence), per-consumer enablement, verify, rollback per consumer.
- `docs/diagrams/s3-object-store-topology.md`: who writes to which bucket, with what credentials, on what cadence.
- `docs/runbooks/do-bring-up.md`: Phase 2 section gets an "S3 bucket prereq" note for etcd snapshots (must exist before `make play` on bring-up #1, or RKE2 skips snapshot config).
- `docs/TROUBLESHOOTING.md`: new "S3 backup target" section covering common failure modes (bucket missing, credentials wrong, endpoint typo, Wasabi 90-day minimum surprise).

## Out of scope (explicit non-goals)

- **No actual Wasabi provisioning.** Phase 4 work. This change stubs the abstraction but only implements `do_spaces`.
- **No backup *restore* automation.** Manual operator process documented in the runbook. Restore is rare + high-stakes; operator-driven is right.
- **No image-registry / log-shipping / metrics-storage** even though those also speak S3. Separate future changes.
- **No bucket policy / IAM hardening beyond minimum** (the credentials Tofu generates have full bucket access; operator can tighten later if desired).
- **No automated CI for this change.** Manual operator validation per the runbook.

## Decisions to lock in (review-driven)

1. **One umbrella proposal, three consumer-shipped PRs.** The shared substrate (Tofu module, Ansible plumbing variables, credential layout, naming) lands in PR 1. Each consumer (Tofu state migration, etcd snapshots, Longhorn backup) ships as its own focused follow-up PR with its own validation. Reason: blast radii are different — Tofu state migration is a one-shot destructive op; etcd snapshots are operationally critical; Longhorn backup is a "nice to have" not on the critical path. Reviewing them mixed together obscures the trade-offs.
2. **DO Spaces for Phase 3 test, Wasabi for Phase 4 prod.** Test phase already pays for DO; Wasabi's 90-day-minimum + free-egress model fits long-retention prod better. Abstraction designed so the swap is `.tfvars` + `secrets.enc.tfvars` only.
3. **One bucket per consumer**, not one shared bucket with prefixes. Cleaner lifecycle policies (different retention per consumer), cleaner blast radius if credentials leak, cleaner accounting. Cost difference is negligible — DO Spaces bills per-bucket above the first.
4. **Tofu state migration is operator-manual.** `tofu init -migrate-state` is well-documented upstream; wrapping it in `make` adds risk for marginal convenience. Runbook captures the exact sequence + rollback.
5. **Snapshot retention defaults: etcd 7d, Longhorn 30d, Tofu state versioned indefinitely.** Etcd snapshots are large + frequent + low-value past a week (cluster destroy/rebuild beats snapshot restore at the tooling we have). Longhorn backups are application data — month-long retention. Tofu state is small + critical — keep all versions. All three operator-overridable.
6. **Credentials per provider, not per consumer.** One Spaces access key with bucket-wide R/W is supplied via SOPS to all three consumers. Operator can later split by consumer when policy supports it; for now one key keeps the rotation story simple. Wasabi gets a separate operator-managed key in Phase 4.

## Success criteria

- `tofu -chdir=terraform/environments/do-test apply` provisions 3 Spaces buckets with versioning + the expected lifecycle policy; outputs populated.
- `tofu init -migrate-state` after switching `backend "local"` → `backend "s3"` succeeds; `tofu plan` reports no diff post-migration; local `terraform.tfstate` removed safely.
- After `make play`, every CP's `/etc/rancher/rke2/config.yaml` includes the etcd-s3 keys; `journalctl -u rke2-server` shows snapshot taken on first scheduled cron tick (or via `kubectl get etcdsnapshotfile` if RKE2 exposes the CR).
- Listing the etcd snapshot bucket shows snapshots arriving on the configured cadence; lifecycle policy ages them out at 7d.
- After Flux reconciles the new Longhorn values, `kubectl -n longhorn-system get backuptargets` shows the configured S3 target as `available: true`.
- A manual backup of a test PVC succeeds (`kubectl apply -f` a `Backup` CR or via Longhorn UI); the backup appears in the Longhorn backup bucket; restore-from-backup creates a usable PV.
- All three buckets visible in DO control panel with versioning + lifecycle policy configured per the design table.
- `make destroy` + a fresh `make apply` recreates buckets cleanly (or: confirms `prevent_destroy = true` on `tofu_state` bucket if we end up adding it — see design.md).
- `docs/runbooks/s3-object-store-enablement.md` + diagram + TROUBLESHOOTING.md section exist and cross-link.

## Sequencing note

PR 1 (substrate) needs no cluster — just Tofu module + Ansible variable scaffolding + docs.
PR 2 (Tofu state migration) is a one-shot operator workflow against the local laptop; no cluster needed but blocks all subsequent Tofu work cluster-wide.
PR 3 (etcd snapshots) needs a fresh cluster bring-up to validate snapshots actually flow.
PR 4 (Longhorn backup target) same — needs cluster + a real PVC.

PR 1 can land + be reviewed immediately. PR 2-4 land + validate at the next planned bring-up.

## Known blockers / related work

- **Existing Longhorn `defaultBackupStore` placeholder in `apps/longhorn/values.yaml`** (lines 273-280) points at `s3://evanstest@us-west-1/` with secret name `evanstest` — leftover from the upstream `fluxcd-template` vendor pattern, no matching Secret in cluster. Currently a no-op (Longhorn reports the backup target unavailable but cluster operates fine). This proposal makes it actually work.
- **`enable-longhorn` archived proposal** explicitly deferred backup target to a separate change citing "no S3 endpoint configured yet" — this is that change.
- **PR #54** added `letsencrypt-staging` ClusterIssuer for test certs; the LE prod issuance is still unverified end-to-end (memory note). Independent of this proposal but might be done in parallel at the next bring-up.

## Tracking

Tracking issue: TBD. Predecessors: `add-do-droplet-module` (DO provider already loaded), `enable-longhorn` (Longhorn cluster-side already in place, only backup target wiring left). Successors: future `enable-do-spaces-cdn` (if web-facing static assets ever need S3), future Phase-4 `enable-wasabi-object-store` (the same abstraction, different provider values).
