# Tasks — enable-s3-object-store

Implementation is split across 4 sequential PRs. PR 1 lands the substrate (no cluster needed). PR 2 is a one-shot operator workflow (Tofu state migration, no cluster needed). PR 3 + PR 4 ship one consumer each and validate at the next cluster bring-up.

## PR 1 — substrate (do-spaces module + var scaffolding + docs)

No cluster required. Reviewable + mergeable independently.

### Tofu module

- [ ] 1. Create `terraform/modules/do-spaces/`:
  - `main.tf`: `digitalocean_spaces_bucket` (× len(`var.buckets`)), `digitalocean_spaces_bucket_object` (lifecycle policy XML if the provider's `lifecycle_rule` block doesn't cover it cleanly).
  - `variables.tf`: `cluster_name`, `region`, `buckets` (list of consumer names: `tofu_state`, `etcd_snapshots`, `longhorn_backups`), `etcd_snapshot_retention_days` (default 7), `longhorn_backup_retention_days` (default 30).
  - `outputs.tf`: per-bucket name, endpoint (derived from region), region, plus access_key_id + secret_access_key surfaced from a `digitalocean_spaces_keys` resource (or operator-supplied — see decision below).
- [ ] 2. **Decide**: does the module create the Spaces access key, or does the operator supply one out-of-band? Recommendation: operator-supplied (Tofu can read it via `var.object_store_access_key` / `var.object_store_secret_key`), because rotating a Tofu-managed credential implies a Tofu apply, which uses the credential to authenticate — chicken-and-egg again. Operator rotation in DO control panel is cleaner.

### Root env wiring

- [ ] 3. Add to `terraform/environments/do-test/variables.tf`:
  - `object_store_provider` (default `"do_spaces"`, validation list `["do_spaces", "wasabi"]`)
  - `object_store_region` (default `"nyc3"`)
  - `object_store_endpoint` (default `null` — derived if null, override otherwise)
  - `object_store_access_key` (sensitive, no default)
  - `object_store_secret_key` (sensitive, no default)
  - `etcd_snapshot_retention_days` (default 7)
  - `longhorn_backup_retention_days` (default 30)
- [ ] 4. `terraform/environments/do-test/main.tf` — add `module "spaces"` block, conditional on `var.object_store_provider == "do_spaces"`.
- [ ] 5. `terraform/environments/do-test/outputs.tf` — surface `tofu_state_bucket`, `etcd_snapshot_bucket`, `longhorn_backup_bucket`, `object_store_endpoint`, `object_store_region`. Credentials NOT exposed as outputs (they live in `secrets.enc.tfvars`, surfaced into Ansible via the inventory renderer).
- [ ] 6. `terraform/environments/do-test/terraform.tfvars.example` — document the new vars + their Phase-3 (`do_spaces`) defaults.
- [ ] 7. Update `terraform/environments/do-test/secrets.enc.tfvars`: add `object_store_access_key` + `object_store_secret_key`. Operator creates the Spaces key via DO control panel beforehand.

### Ansible inventory render

- [ ] 8. `ansible/scripts/render-inventory.py`: emit Tofu outputs (`etcd_snapshot_bucket`, `object_store_endpoint`, `object_store_region`) into `group_vars/all/main.yml`. Credentials remain in `group_vars/all/secrets.yaml` (operator copies them from `secrets.enc.tfvars` post-apply — documented in runbook).

### Docs

- [ ] 9. `docs/runbooks/s3-object-store-enablement.md` — full operator procedure: prereqs (create Spaces key in DO panel), bucket provisioning sequence, per-consumer enable steps, per-consumer verify steps, per-consumer rollback. Bucket retention table. Wasabi swap-in notes (Phase 4).
- [ ] 10. `docs/diagrams/s3-object-store-topology.md` — Mermaid of who writes to which bucket, with what credentials, on what cadence.
- [ ] 11. `docs/runbooks/do-bring-up.md` — add "S3 bucket prereq" note in Phase 2: if etcd snapshots will be enabled, the bucket must exist before `make play` runs the rke2_server role.
- [ ] 12. `docs/TROUBLESHOOTING.md` — new "S3 / object store" section. Index entries for: bucket missing, credentials wrong, endpoint typo, Wasabi 90-day minimum surprise, Tofu state lock-not-released.
- [ ] 13. `README.md` — Phase 3 row gets an S3-backed-storage sub-bullet.

### Close-out PR 1

- [ ] 14. `kubectl kustomize apps/longhorn/` still renders cleanly (we haven't touched it yet).
- [ ] 15. `tofu -chdir=terraform/environments/do-test validate` passes.
- [ ] 16. Open tracking issue `Phase 3d — enable S3 object store`. Body links openspec dir + lists PR 1-4.
- [ ] 17. Commits grouped:
  - `feat(tofu): add do-spaces module + root-env wiring (do_spaces only, wasabi stubbed)`
  - `feat(ansible): render-inventory emits object_store_* into group_vars`
  - `docs: s3-object-store runbook + topology diagram + TROUBLESHOOTING section`
- [ ] 18. PR title: `feat(s3): substrate for object-store backed Tofu state + etcd + Longhorn backups`. Body: link openspec + note that consumers ship in PR 2-4.
- [ ] 19. Merge PR 1.

## PR 2 — Tofu remote state migration (#3)

No cluster required, but blocks ALL subsequent Tofu work. Operator-driven one-shot.

- [ ] 20. Pre-flight: `tofu -chdir=terraform/environments/do-test apply` (creates the buckets using local state).
- [ ] 21. Verify all 3 buckets exist in DO panel with the expected lifecycle policy.
- [ ] 22. Create `terraform/environments/do-test/backend.tf`:
  ```hcl
  terraform {
    backend "s3" {
      bucket                      = "do-nyc3-rke2-demo-tofu-state"
      key                         = "do-test/terraform.tfstate"
      region                      = "us-east-1"           # required, Spaces ignores
      endpoint                    = "https://nyc3.digitaloceanspaces.com"
      skip_credentials_validation = true
      skip_metadata_api_check     = true
      skip_region_validation      = true
      skip_requesting_account_id  = true
      use_lockfile                = true                   # OpenTofu 1.10+: object-store native locking
      use_path_style              = false
    }
  }
  ```
- [ ] 23. Back up local `terraform/environments/do-test/terraform.tfstate` to operator-local safe location (NOT in repo).
- [ ] 24. Run `tofu -chdir=terraform/environments/do-test init -migrate-state -backend-config="access_key=$(...)" -backend-config="secret_key=$(...)"`. Confirm prompt.
- [ ] 25. Verify migration: `tofu -chdir=terraform/environments/do-test plan` reports no diff.
- [ ] 26. Confirm local `terraform.tfstate` is gone (Tofu deletes it post-migration).
- [ ] 27. Commit `backend.tf` only (the state file was never in repo and is gone now).
- [ ] 28. PR title: `feat(tofu): migrate state to do-spaces s3 backend (closes #3)`. Body documents the one-shot operator workflow + rollback.
- [ ] 29. Merge PR 2.

## PR 3 — etcd snapshots (#8)

Needs fresh cluster bring-up to validate.

- [ ] 30. `ansible/roles/rke2_server/templates/config.yaml.j2` — add the `etcd-s3` block (see design.md). Conditional on `etcd_snapshot_s3_enabled`.
- [ ] 31. `ansible/inventory/group_vars/all/main.yml` — defaults: `etcd_snapshot_s3_enabled: true`, `etcd_snapshot_schedule: "0 */6 * * *"`, `etcd_snapshot_retention: 28`.
- [ ] 32. `ansible/inventory/group_vars/all/secrets.yaml` (SOPS-encrypted) — add `etcd_snapshot_s3_access_key` + `etcd_snapshot_s3_secret_key`. Operator copies from `terraform secrets.enc.tfvars` (same Spaces key).
- [ ] 33. `docs/runbooks/s3-object-store-enablement.md` — fill in PR 3 enable + verify steps.
- [ ] 34. PR title: `feat(rke2): etcd snapshots to s3-compatible bucket (closes #8)`. Merge.
- [ ] 35. At next cluster bring-up: `make play` → SSH a CP → `cat /etc/rancher/rke2/config.yaml | grep etcd-s3` shows the block populated. `journalctl -u rke2-server | grep -i snapshot` shows snapshot taken at cron tick. List bucket contents — snapshot present. Lifecycle policy verified by waiting 7d + 1 OR by setting a short test retention.
- [ ] 35a. **Incidental validation — LE prod issuance against escapekey.org** (closes the unverified-LE memory note carried forward from `dns-migration-to-do`). On the same bring-up:
  - Confirm the existing `letsencrypt-prod` ClusterIssuer reconciles cleanly (already shipped via `apps/cert-manager-custom-resources/`).
  - Create a one-off test Ingress with annotation `cert-manager.io/cluster-issuer: letsencrypt-prod` for an `escapekey.org` subdomain (e.g. `lh-prod-canary.escapekey.org`).
  - Watch external-dns publish the A record, watch cert-manager request the cert (DNS-01 via DO), watch LE issue.
  - `curl --resolve` or browser confirms a real (non-staging) cert is served.
  - Tear down the test Ingress + record; record outcome in `docs/runbooks/dns-migration-to-do.md` or `TROUBLESHOOTING.md`.

## PR 4 — Longhorn backup target

Needs cluster + a real PVC to validate end-to-end.

- [ ] 36. `apps/longhorn/values.yaml` — replace the `evanstest` placeholder with templated cluster-real values per design.md.
- [ ] 37. `apps/longhorn/backup-target.secrets.yaml` — new SOPS-encrypted Secret per design.md.
- [ ] 38. `apps/longhorn/kustomization.yaml` — re-add `secretGenerator` for the backup-target Secret.
- [ ] 39. `kubectl kustomize apps/longhorn/` renders cleanly.
- [ ] 40. `docs/runbooks/s3-object-store-enablement.md` — fill in PR 4 enable + verify steps.
- [ ] 41. PR title: `feat(longhorn): wire backup target to s3-compatible bucket`. Merge.
- [ ] 42. At cluster bring-up: Flux reconciles → `kubectl -n longhorn-system get backuptargets` shows the configured target with `available: true`. Create a test PVC + writer pod. Trigger a backup (via Longhorn UI or `kubectl apply` of a `Backup` CR). Verify the backup appears in the bucket. Restore-from-backup creates a usable PV. Tear down.

## Archive

- [ ] 43. After all 4 PRs merged + validated, `git mv openspec/changes/enable-s3-object-store openspec/changes/archive/<YYYY-MM-DD>-enable-s3-object-store`. Commit `docs(openspec): archive enable-s3-object-store`.
