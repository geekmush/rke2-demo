# Tasks — add-fluxcd-bootstrap

**Tracking issue:** [#16](https://github.com/geekmush/rke2-demo/issues/16)

Implementation order. Each numbered task is a discrete-commit-sized chunk; commit subjects in task 13.

## File changes (this PR)

- [x] 1. Author `apps/cert-manager-custom-resources/selfsigned-clusterissuer.yaml` (minimal self-signed ClusterIssuer).
- [x] 2. Update `apps/cert-manager-custom-resources/kustomization.yaml` to reference it.
- [x] 3. Edit `variables.sh`: replace `SOPS_AGE_KEY=$(age -d ...)` with `SOPS_AGE_KEY_FILE="${sops_dir}/keys.txt"`. Comment explains why (plaintext keys.txt; template assumed encrypted).
- [x] 4. Edit `deploy.sh`'s `rke2)` case: `app_list=""` with a comment pointing at Phase 3c restoration.
- [x] 5. Create the sops-age Secret:
  - Compose plaintext `flux/flux-system/sops-age.secrets.yaml.decrypted` with `stringData.age.agekey` set to the operator's full `~/.config/sops/age/keys.txt` content.
  - SOPS-encrypt to `flux/flux-system/sops-age.secrets.yaml`.
  - Remove the `.decrypted` file (do not commit it).
  - Verify `sops -d` round-trips cleanly with the operator's age key.
- [x] 6. Author `docs/runbooks/fluxcd-bootstrap.md`: prereqs (DNS state, DO token scopes, GitHub PAT generation + scopes), deploy.sh execution flow, verification commands (Flux controllers, Kustomizations, ClusterIssuers, test cert), expected fluxcdbot commits, troubleshooting (bootstrap failure / deploy key cleanup, sops-age secret recreation, ingress-nginx pending External-IP), rollback notes.
- [x] 7. Validate in PR:
  - SOPS round-trip clean on the new sops-age.secrets.yaml.
  - `kubectl kustomize apps/cert-manager-custom-resources/` clean.
  - `kustomize build flux/flux-system/` -- if it works pre-bootstrap (some references may need to wait for Flux); ok to skip if it errors on missing controllers.

## Operator execution (after merge -- NOT in PR commits)

- [x] 8. Generate fresh fine-grained GitHub PAT (`Administration:RW + Contents:RW` on `geekmush/rke2-demo`). Set via `read -s GITHUB_TOKEN; export GITHUB_TOKEN` (not pasted into chat).
- [x] 9. `source variables.sh` -- loads env.
- [x] 10. `./deploy.sh` -- runs end-to-end. Output captured for the PR close-out comment.
- [x] 11. Verify per runbook checklist:
  - 6 Flux controllers Ready
  - all Kustomizations Ready (or expected-failure documented for letsencrypt)
  - cert-manager pods Ready
  - ingress-nginx controller Ready (Service in `<pending>` external IP -- expected)
  - external-dns pod Ready
  - both ClusterIssuers exist (`letsencrypt` degraded, `selfsigned` Ready)
- [x] 12. Apply the runbook's test `Certificate` manifest against the `selfsigned` ClusterIssuer; confirm `Ready=True` within 60s; produce the `tls.crt` Secret; delete the test Certificate.

## Close-out

- [x] 13. Open PR. Title: `Phase 3b: bootstrap FluxCD onto the cluster (closes #16)`. Suggested commit split:
  - `docs(openspec): propose add-fluxcd-bootstrap`
  - `feat(fluxcd-template): add self-signed ClusterIssuer for DNS-independent cert testing`
  - `fix(fluxcd-template): support plaintext age keys.txt via SOPS_AGE_KEY_FILE`
  - `chore(fluxcd-template): drop longhorn from rke2 case for Phase 3b (restored in 3c)`
  - `feat(fluxcd-template): SOPS-encrypted sops-age secret for in-cluster Flux decryption`
  - `docs(runbook): FluxCD bootstrap procedure`
- [x] 14. Walk safe-staging checklist (sops-age secret must be ENC blob; no plaintext private age key anywhere).
- [x] 15. Merge.
- [x] 16. Run operator-side execution (tasks 8-12) on the live cluster.
- [x] 17. Comment on the merged PR with the verification output.
- [x] 18. Archive change directory: `git mv openspec/changes/add-fluxcd-bootstrap openspec/changes/archive/<date>-add-fluxcd-bootstrap`.
