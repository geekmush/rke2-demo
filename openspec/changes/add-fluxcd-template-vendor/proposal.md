# Proposal — add-fluxcd-template-vendor

**Tracking issue:** [#14](https://github.com/geekmush/rke2-demo/issues/14)
**Phase:** 3 — GitOps
**Status:** proposed

## Why

Phase 3 begins. FluxCD will own platform components (cert-manager, ingress-nginx, external-dns) and apps (Longhorn next, more later) as committed `HelmRelease` / `Kustomization` artifacts in this repo. Vendoring `devopscoop/fluxcd-template` at the root gives us a maintained, well-shaped GitOps tree; future updates are `git pull fluxcd-template main`.

This change is **file-only prep** -- the tree is adapted to this repo's conventions and ready for `deploy.sh` execution in Phase 3b. No cluster-side changes here.

## What this change ships

- **Vendored tree at repo root** via `git merge --allow-unrelated-histories fluxcd-template/main`. After merge:
  - `apps/` -- per-app kustomizations + HelmReleases + values + secrets
  - `flux/flux-system/` -- Flux sync manifests + per-platform kustomization entries
  - `deploy.sh`, `deploy_new_app.sh`, `encrypt_secrets.sh` -- operator entry points
  - `variables.sh` -- repo-wide settings (cluster name, git owner, platform, etc.)
  - `bin/` (empty -- script-managed tool cache)
- **Collision resolutions**:
  - `.sops.yaml` -- union of rules (ours: `*.enc.*`; template's: `secrets.yaml`, `helm_secrets.yaml`), single age recipient (operator's existing key).
  - `.gitignore` -- union (ours: Tofu/Ansible/Claude-state; template's: `bin/*`, `*.decrypted`).
  - `CODEOWNERS` -- replaced with `* @geekmush`.
  - `README.md` -- ours wins; template's moves to `docs/upstream/fluxcd-template-README.md`.
- **`project1-dev` -> `rke2-demo` rewrite** across the vendored tree (excluding `deploy.sh`, which has its own rewrite logic).
- **`variables.sh`** set with `git_platform=github`, `git_owner=geekmush`, `git_repo=rke2-demo`, `cluster_name=rke2-demo`, `k8s_platform=rke2`.
- **New `rke2` platform case** in `deploy.sh` -- k0s-derived `core_app_list` plus `longhorn`, minus `rook-ceph*` and `metallb*`.
- **DNS provider swap Cloudflare -> DigitalOcean**:
  - `apps/external-dns/values.yaml` -- provider, env, secret references.
  - `apps/cert-manager-custom-resources/clusterissuer.yaml` -- DNS-01 solver pointed at the DigitalOcean provider.
  - `apps/external-dns/secrets.yaml` -- new, SOPS-encrypted Kubernetes Secret carrying `DO_TOKEN`.
  - `apps/cert-manager-custom-resources/digitalocean-dns.secrets.yaml` -- new, SOPS-encrypted Secret carrying the same token (cert-manager namespace).
  - Old `cloudflare-apikey-secret.secrets.yaml.decrypted` -- removed; replaced by the digitalocean-dns secret.
  - `kustomization.yaml` resource lists updated.
- **`enableGatewayAPI: false`** in `apps/cert-manager/values.yaml` -- template defaults to `true` but Gateway API CRDs aren't installed; cert-manager would fail webhook readiness. Re-enable when/if Gateway API lands.
- **Existing SOPS file retrofit**:
  - `ansible/inventory/group_vars/all/secrets.enc.yaml` -> `ansible/inventory/group_vars/all/secrets.yaml`. Same content, same age key, template-aligned filename. `ansible.cfg`'s `valid_extensions` broadened to `.yaml,.yml,.json` and `handle_unencrypted_files = skip` added so plain `main.yml` is skipped by the SOPS plugin and loaded by `host_group_vars` instead.
  - `terraform/environments/do-test/secrets.enc.tfvars` -- stays as-is. Template's `secrets.yaml` regex is YAML-only; tfvars are a different shape.
- **New `cluster_name` Ansible variable** -- `inventory/group_vars/all/main.yml`. Used by `operator_kubeconfig_path: "{{ lookup('env','HOME') }}/.kube/{{ cluster_name }}"`. Default `rke2-demo`.
- **CLAUDE.md update** -- file-layout section grows new top-level entries; new "FluxCD vendor pattern" section covers how to pull upstream updates, add a new app, and where new secrets live.
- **README.md update** -- minor; phase-table polish if needed.

## Out of scope (explicit non-goals)

- **No `deploy.sh` execution.** No `flux bootstrap`, no cluster-side reconciliation. Phase 3b.
- **No Longhorn enablement.** Phase 3c (`longhorn` app gets added to `flux/flux-system/kustomization.yaml`'s resource list and Longhorn-specific config lands then).
- **No GitHub Actions / CI.** User confirmed skip.
- **No upstream contributions** back to devopscoop. The `rke2` platform case and the DO DNS provider option are good candidate Phase 5 PRs to `devopscoop/fluxcd-template`.
- **No image automation policies/repositories.** Template's `core_app_list` for k0s includes `imagepolicies`, `imagerepositories`, `imageupdateautomation` -- our `rke2` case OMITS those until we have in-house apps using the dev-tag pattern.

## Decisions locked in (from review on 2026-05-15)

1. **Vendoring** at repo root via `git merge --allow-unrelated-histories`. Future upstream pulls via `git pull fluxcd-template main`.
2. **GitHub Actions skipped for now.** Image automation runs in-cluster post-bootstrap (Phase 3b).
3. **Three-PR Phase 3 split**: 3a (this PR -- vendor + adapt), 3b (`deploy.sh` bootstrap), 3c (Longhorn enablement).
4. **MetalLB omitted** from the rke2 platform case. We use a DO LB for CP; no in-cluster L2 LB needed yet.
5. **README.md collision** -- ours wins; template's moves to `docs/upstream/` for reference.
6. **`enableGatewayAPI: false`** on cert-manager.
7. **CODEOWNERS** replaced with `* @geekmush`.
8. **SOPS retrofit** -- rename existing `.enc.yaml` to `secrets.yaml` template convention; merge `.sops.yaml` rules; single age recipient.

## Success criteria

- `git log --oneline` shows a clean merge commit plus the planned adaptation commits, no AI-attribution trailers.
- All SOPS-encrypted files in the tree decrypt with the operator age key (`sops -d` on each `*.secrets.yaml` and `*.enc.tfvars` returns plaintext).
- `kustomize build` clean over `apps/*/` and `flux/flux-system/`.
- `tofu validate` still passes (no Tofu changes in this PR, but sanity).
- `make -C ansible play` reports idempotent across all 6 hosts after the `cluster_name` introduction.
- Zero plaintext credentials in any committed file.
- Vendored upstream files unchanged except where listed in tasks.md; future `git pull fluxcd-template main` is conflict-free for upstream-untouched files.

## Tracking

Issue #14. Depends on every prior Phase 1+2 PR (#2, #5, #7, #10, #12, #13). Unblocks Phase 3b (run `deploy.sh`) and Phase 3c (Longhorn).
