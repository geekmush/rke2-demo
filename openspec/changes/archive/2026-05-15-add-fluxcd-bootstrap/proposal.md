# Proposal — add-fluxcd-bootstrap

**Tracking issue:** [#16](https://github.com/geekmush/rke2-demo/issues/16) (closed)
**Phase:** 3 — GitOps
**Status:** archived 2026-05-15 -- shipped via [PR #17](https://github.com/geekmush/rke2-demo/pull/17). 4 issues found + fixed during operator execution (see PR comment + issue #18 / PR #19 for the Phase 1 Canal/Flannel VXLAN bug).

## Why

Phase 3a vendored `devopscoop/fluxcd-template` and adapted it for rke2-demo. Phase 3b actually bootstraps FluxCD against the live cluster and reconciles the core platform apps (cert-manager, ingress-nginx, external-dns + their dependencies). Phase 3c lands Longhorn on top of that.

This PR is **file-only**. The actual `deploy.sh` execution happens operator-side after merge, same pattern as Phase 1's `make apply`.

## What this change ships in the PR

- **`apps/cert-manager-custom-resources/selfsigned-clusterissuer.yaml`** -- a self-signed ClusterIssuer. Lets us test cert-manager works end-to-end without depending on ACME (which is blocked on Dreamhost DNS delegation propagating). Kept long-term -- useful for cluster-internal TLS / mTLS use cases that don't need a publicly-trusted CA.
- **`apps/cert-manager-custom-resources/kustomization.yaml`** -- references the new file.
- **`variables.sh`** -- replace `SOPS_AGE_KEY=$(age -d "${sops_dir}/keys.txt")` with `SOPS_AGE_KEY_FILE="${sops_dir}/keys.txt"`. Our keys.txt is plaintext (per the workstation setup runbook); the template assumes age-passphrase-encrypted.
- **`deploy.sh`** -- temporarily set the `rke2)` case to `app_list=""`. Restored to `app_list="longhorn.yaml"` in Phase 3c, alongside the longhorn-config fixes. Phase 3b commit subject calls this out so 3c is easy to spot.
- **`flux/flux-system/sops-age.secrets.yaml`** -- new, SOPS-encrypted. Carries a Kubernetes `Secret` manifest containing the operator's age **private** key under `stringData.age.agekey`. Encryption is self-referential -- operator's age public key is the recipient; their private key decrypts. `deploy.sh` runs `sops -d` locally and pipes to `kubectl apply -f -` to install the Secret in `flux-system` namespace BEFORE `flux bootstrap`; from then on Flux uses it to decrypt the rest of the SOPS-encrypted tree at reconciliation time.
- **`docs/runbooks/fluxcd-bootstrap.md`** -- operator-side execution procedure: prereqs, GitHub PAT scopes, env setup, deploy.sh invocation, verification commands, expected commits on main, troubleshooting, rollback notes.

## What happens after the PR merges (operator-side execution)

Not in the PR commit graph but documented in the runbook:

1. Operator generates a fresh fine-grained GitHub PAT (`Administration:RW` + `Contents:RW` on `geekmush/rke2-demo`). Sets via `export GITHUB_TOKEN=...` in a shell that won't persist to history.
2. `source variables.sh` to load env (cluster_name, kubeconfig path, SOPS_AGE_KEY_FILE, tool versions).
3. `./deploy.sh` runs end-to-end:
   - Downloads `kubectl`, `flux`, `sops`, `yq` into `bin/` (versions pinned in variables.sh).
   - `sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -` -- installs the sops-age Secret in `flux-system` namespace.
   - `flux bootstrap github --owner=geekmush --repository=rke2-demo --path=flux --read-write-key --components-extra=image-reflector-controller,image-automation-controller` -- installs Flux controllers cluster-side, creates a deploy key on the GitHub repo, generates `flux/flux-system/gotk-components.yaml` + `gotk-sync.yaml`, commits + pushes via the deploy key.
   - Patches `flux/flux-system/gotk-sync.yaml` with `spec.decryption: {provider: sops, secretRef: {name: sops-age}}`.
   - Appends the `core_app_list` (cert-manager-custom-resources, cert-manager, external-dns, imagepolicies, imagerepositories, imageupdateautomation, ingress-nginx, sops-age.secrets) + our empty `app_list` to `flux/flux-system/kustomization.yaml.resources`.
   - Commits "Enabling Flux Kustomizations" and pushes.
4. Flux reconciles the resulting tree. cert-manager + ingress-nginx + external-dns + the various Flux Kustomizations all install.
5. Operator verifies per runbook, applies + checks the test Certificate, comments on the merged PR with the output.

## Out of scope (deliberate)

- **Longhorn enablement** -- Phase 3c.
- **ACME Let's Encrypt cert issuance** -- blocked on DNS propagation. The `letsencrypt` ClusterIssuer is created but cannot issue real certs (DNS-01 challenge to a zone that nothing serves yet). The `selfsigned` ClusterIssuer covers Phase 3b's "cert-manager works end-to-end" verification independently.
- **Real DNS records appearing externally** -- external-dns runs and reconciles to the DO API, but DO won't serve those records until the Dreamhost delegation propagates. Cluster-side, external-dns will log success and be Ready.
- **In-house application apps** -- nothing yet.
- **flux bootstrap commits going through PR review** -- bootstrap pushes directly to `main` via the deploy key. This is the standard FluxCD pattern. Documented in the runbook.

## Decisions locked in (from review on 2026-05-15)

1. **Path B for Longhorn** -- temporarily drop `longhorn.yaml` from `deploy.sh`'s `rke2)` case in 3b; restore in 3c.
2. **Self-signed ClusterIssuer** added in 3b, kept long-term.
3. **`variables.sh` workaround option 1** -- `SOPS_AGE_KEY_FILE` env var. Explicit, no shell-level decryption.
4. **sops-age secret committed encrypted** in this PR. Self-referential SOPS encryption.
5. **deploy.sh execution is operator-side** (post-merge). Same model as Phase 1's `make apply`. PR delivers files + runbook; execution + verification happen separately.
6. **`ingress-nginx` Service type** stays `LoadBalancer` (will sit `<pending>` since we don't run DO's cloud controller). Cluster-internal traffic works; external DO LB for app ingress is a future decision.
7. **DNS not propagated** is acceptable for Phase 3b -- `selfsigned` issuer covers cert-manager verification; external-dns reconciles successfully on its side even with no actual DNS visibility outside DO.

## Success criteria

- PR file changes merge cleanly.
- After `deploy.sh` execution:
  - 6 Flux controllers Ready in `flux-system` namespace (source, kustomize, helm, notification, image-reflector, image-automation).
  - All `core_app_list` Flux Kustomizations report `Ready=True` (`kubectl get kustomizations -n flux-system`).
  - cert-manager pods (3 -- controller, webhook, cainjector) all Ready.
  - ingress-nginx controller pod Ready (Service in `<pending>` external-IP state -- expected).
  - external-dns pod Ready.
  - Two ClusterIssuers exist: `letsencrypt` (degraded -- DNS not propagated; expected) and `selfsigned` (Ready).
  - A test `Certificate` against `selfsigned` issues within 60s and produces a `tls.crt` Secret.
- 2-3 commits land on `main` authored by `fluxcdbot@users.noreply.github.com` (Flux bootstrap manifests + "Enabling Flux Kustomizations"). Documented as expected.

## Tracking

Issue #16. Depends on PR #15 (Phase 3a). Unblocks Phase 3c (Longhorn enablement against the worker block-storage volumes).
