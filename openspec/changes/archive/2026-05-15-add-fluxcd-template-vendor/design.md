# Design — add-fluxcd-template-vendor

**Tracking issue:** [#14](https://github.com/geekmush/rke2-demo/issues/14)

## Vendoring mechanics

The exact git sequence:

```bash
git remote add fluxcd-template https://github.com/devopscoop/fluxcd-template.git
git fetch fluxcd-template main
git merge --allow-unrelated-histories --no-commit fluxcd-template/main
# resolve collisions:
#   .sops.yaml      -- merge both rules + keep our age recipient
#   .gitignore      -- merge union
#   CODEOWNERS      -- replace with `* @geekmush`
#   README.md       -- ours wins; template's moves to docs/upstream/fluxcd-template-README.md
git add -A
git commit
```

Future upstream updates:

```bash
git fetch fluxcd-template main
git merge fluxcd-template/main
# resolve any new collisions (typically none if we don't edit upstream files)
```

### Why root vs. subdirectory

The template's scripts (`deploy.sh`, `deploy_new_app.sh`, `encrypt_secrets.sh`) use `${SCRIPT_DIR}` for path resolution so they technically run from any location. But `variables.sh` hardcodes `flux_path=flux` (relative to repo root) and the in-cluster Flux sync references `./flux/flux-system`. Vendoring at root preserves these without patching upstream files; vendoring under `gitops/` would require touching `flux_path`, the in-cluster sync paths, and the Kustomization references. Root-merge keeps the diff to upstream minimal -- easier to pull updates and easier to contribute back.

The collision surface is small (4 files: `.sops.yaml`, `.gitignore`, `CODEOWNERS`, `README.md`). After this PR, the operator-controlled changes live in distinct files that upstream doesn't touch.

## Collision resolutions

### `.sops.yaml`

Ours currently:

```yaml
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env|tfvars)$
    encrypted_regex: '^(data|stringData|.*[Pp]assword|.*[Ss]ecret|.*[Tt]oken|.*[Kk]ey)$'
    age: age1s8ed4qr4k7hvwu6mx5z80prurzz2wcq4gk2ujyh8w75ssaxy44xq8pzjdk
```

Template's:

```yaml
creation_rules:
  - path_regex: '^.*\/(.*\.)?secrets\.yaml$'
    encrypted_regex: "^(data|stringData)$"
    age: YOUR_AGE_PUBLIC_KEY
  - path_regex: '^.*\/(.*\.)?helm_secrets\.yaml$'
    age: YOUR_AGE_PUBLIC_KEY
```

Merged:

```yaml
creation_rules:
  - path_regex: \.enc\.(ya?ml|json|env|tfvars)$
    encrypted_regex: '^(data|stringData|.*[Pp]assword|.*[Ss]ecret|.*[Tt]oken|.*[Kk]ey)$'
    age: age1s8ed4qr4k7hvwu6mx5z80prurzz2wcq4gk2ujyh8w75ssaxy44xq8pzjdk
  - path_regex: '^.*\/(.*\.)?secrets\.yaml$'
    encrypted_regex: '^(data|stringData|.*[Pp]assword|.*[Ss]ecret|.*[Tt]oken|.*[Kk]ey)$'
    age: age1s8ed4qr4k7hvwu6mx5z80prurzz2wcq4gk2ujyh8w75ssaxy44xq8pzjdk
  - path_regex: '^.*\/(.*\.)?helm_secrets\.yaml$'
    age: age1s8ed4qr4k7hvwu6mx5z80prurzz2wcq4gk2ujyh8w75ssaxy44xq8pzjdk
```

Notes:

- We widen template's `secrets.yaml` rule's `encrypted_regex` to match our broader pattern (catches `*_token`, `*_password`, etc., not just K8s-Secret-shaped `data`/`stringData`). This lets the Ansible group_vars `secrets.yaml` file -- which has top-level `rke2_server_token` etc. -- be properly encrypted under the same rule.
- `helm_secrets.yaml` keeps no `encrypted_regex` -- everything in those files is encrypted (they're raw Helm value YAML with no predictable top-level keys).
- Single age recipient -- the operator's existing key. Template's `YOUR_AGE_PUBLIC_KEY` placeholder is dropped.

### `.gitignore`

Merge union. Template adds:

```
bin/*
*.decrypted
```

`bin/*` matches the script-managed binary cache (`deploy.sh` puts `kubectl`, `flux`, `sops`, `yq` there). `*.decrypted` is the operator's local plaintext-secret scratch file convention from `deploy.sh` / `encrypt_secrets.sh`. Both added to our existing `.gitignore`.

### `CODEOWNERS`

Replace template's `* gmail@evanstucker.com` / `* @arterro` with:

```
* @geekmush
```

### `README.md`

Ours wins. Template's `README.md` moves to `docs/upstream/fluxcd-template-README.md` -- preserves the upstream "Deploying Flux" 11-step list for reference when we run `deploy.sh` in Phase 3b.

## `rke2-demo` -> `rke2-demo` rewrite

Single global sed across the vendored tree, excluding files where the placeholder is meaningful for `deploy.sh`'s own runtime substitution:

```bash
find apps flux variables.sh \
  -type f \( -name '*.yaml' -o -name '*.sh' \) \
  -exec sed -i 's/rke2-demo/rke2-demo/g' {} +
```

Touches:

- `apps/external-dns/values.yaml` -- `txtOwnerId`
- `variables.sh` -- `cluster_name`, `git_repo`
- (a handful of other one-line references)

We deliberately do NOT rewrite `deploy.sh` itself because its sed loop reads `cluster_name` from variables.sh and rewrites the tree at execute-time. With our pre-rewrite, `deploy.sh`'s rewrite-step is a no-op -- safer than removing the rewrite logic entirely.

## `variables.sh` settings

```bash
# variables.sh -- after this PR
sops_dir="${HOME}/.config/sops/age"   # unchanged from template
cluster_name="rke2-demo"
git_platform="github"                  # template default was "gitlab"
git_owner="geekmush"
git_repo="rke2-demo"                   # was "rke2-demo-deploy"
k8s_platform="rke2"                    # NEW -- adds the rke2 case
KUBECONFIG="${HOME}/.kube/${cluster_name}"
```

## `deploy.sh` `rke2` platform case

Add a new branch in the `case "${k8s_platform}"` switch:

```bash
rke2)
  # Same core_app_list as k0s, minus rook-ceph (Longhorn instead) and
  # metallb (DO LB handles CP traffic; no in-cluster L2 LB needed).
  additional_apps=(longhorn)
  ;;
```

This drops:
- `rook-ceph` / `rook-ceph-cluster` (replaced by Longhorn)
- `metallb` / `metallb-custom-resources` (decision #4)
- `imagepolicies` / `imagerepositories` / `imageupdateautomation` (no in-house apps yet)

Implementation detail: `core_app_list` and `additional_apps` get concatenated into the kustomization.yaml resource list at deploy time. Verify by reading the script's tail loop -- the rke2 branch should land in the same shape as the existing k0s/talos/eks branches.

## DNS provider swap

### `apps/external-dns/values.yaml`

Before:

```yaml
provider:
  name: cloudflare
  webhook:
    args:
      - --cloudflare-dns-records-per-page=5000
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-api-key
        key: apiKey
```

After:

```yaml
provider: digitalocean
env:
  - name: DO_TOKEN
    valueFrom:
      secretKeyRef:
        name: digitalocean-dns
        key: access-token
```

`provider: digitalocean` (top-level string, not nested `name:`) per the external-dns chart 1.20.0 schema for DO. No webhook block needed -- DO is a built-in provider.

### `apps/cert-manager-custom-resources/clusterissuer.yaml`

Uncomment the DNS-01 solver and point it at DigitalOcean:

```yaml
solvers:
  - dns01:
      digitalocean:
        tokenSecretRef:
          name: digitalocean-dns
          key: access-token
  - http01:
      ingress:
        ingressClassName: nginx
```

Keep the http01 solver as a fallback for ingress-served paths. cert-manager picks the right solver based on what the certificate request needs.

### New `apps/external-dns/secrets.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean-dns
  namespace: external-dns
type: Opaque
stringData:
  access-token: <sops-encrypted>
```

The token value is the same DO API token already in `terraform/environments/do-test/secrets.enc.tfvars`. Encrypted independently here per template convention (one Secret per app, no cross-namespace sharing).

### New `apps/cert-manager-custom-resources/digitalocean-dns.secrets.yaml`

Same shape, `namespace: cert-manager`. Old `cloudflare-apikey-secret.secrets.yaml.decrypted` is removed.

### Kustomization updates

`apps/cert-manager-custom-resources/kustomization.yaml` resource list:

```yaml
resources:
  - clusterissuer.yaml
  - digitalocean-dns.secrets.yaml   # was: cloudflare-apikey-secret.secrets.yaml
```

`apps/external-dns/kustomization.yaml` resource list -- add `secrets.yaml` if not already present.

## Existing SOPS file retrofit

### `ansible/inventory/group_vars/all/secrets.enc.yaml` -> `secrets.yaml`

Rename only; content unchanged. The new filename matches template's `^.*\/(.*\.)?secrets\.yaml$` regex.

`ansible.cfg` updates:

```ini
[community.sops]
valid_extensions      = .yaml,.yml,.json
handle_unencrypted_files = skip
```

`valid_extensions` is broadened to match any YAML/JSON file (not just `.enc.*`). `handle_unencrypted_files: skip` (requires SOPS 3.9.0+) tells the plugin to skip files that match the extension but aren't actually SOPS-encrypted -- so `main.yml` (plain YAML) is silently passed to `host_group_vars` instead of erroring.

### Terraform-side

`terraform/environments/do-test/secrets.enc.tfvars` stays at `.enc.tfvars`. Template's `secrets.yaml` regex is YAML-only; tfvars are a different shape with their own existing `.enc.tfvars` regex in `.sops.yaml`.

## Ansible `cluster_name` variable

`inventory/group_vars/all/main.yml` gains:

```yaml
cluster_name: rke2-demo
operator_kubeconfig_path: "{{ lookup('env', 'HOME') }}/.kube/{{ cluster_name }}"
```

Existing hardcoded `~/.kube/rke2-demo` becomes a templated lookup. The kubeconfig file path is unchanged in practice; the variable's introduction sets up Phase 4 (different cluster_name on bare metal) without re-touching everything.

## cert-manager Gateway API

`apps/cert-manager/values.yaml` template default:

```yaml
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  enableGatewayAPI: true
```

We don't have Gateway API CRDs installed (RKE2 ships ingress-nginx-style routing; no Gateway resources). cert-manager with `enableGatewayAPI: true` and no CRDs will fail webhook readiness on start. Set:

```yaml
config:
  apiVersion: controller.config.cert-manager.io/v1alpha1
  kind: ControllerConfiguration
  enableGatewayAPI: false
```

Re-enable in a future change when Gateway API lands in our cluster.

## CLAUDE.md updates

The file-layout section grows new top-level entries:

```
.
├── CLAUDE.md
├── README.md
├── apps/                # NEW -- FluxCD app configs (vendored from devopscoop)
├── ansible/
├── bin/                 # NEW -- script-managed binary cache (gitignored)
├── deploy.sh            # NEW -- vendored
├── deploy_new_app.sh    # NEW -- vendored
├── docs/
├── encrypt_secrets.sh   # NEW -- vendored
├── flux/                # NEW -- Flux sync manifests (vendored)
├── openspec/
├── terraform/
└── variables.sh         # NEW -- vendored, edited
```

New section "## FluxCD vendor pattern":

- How to pull upstream updates (`git fetch fluxcd-template main && git merge fluxcd-template/main`).
- How to add a new app (`./deploy_new_app.sh ...`; produces `apps/<name>/` skeleton).
- Where new secrets live (per-app `secrets.yaml` or `helm_secrets.yaml`).
- The `.decrypted` operator workflow.

Existing groundrule wording stays; only file-layout + the new section grow.

## Risks / open questions

- **Merge conflicts beyond the four listed files.** Possible if upstream changes between investigation and merge time. The four listed are the only ones currently colliding by name. Will document any new ones at merge time.
- **External-dns chart 1.20.0 schema for DigitalOcean** -- I'm working from cert-manager + external-dns docs. The `provider: digitalocean` (top-level string) form may need to be `provider: { name: digitalocean }` (nested object) on this chart version. Will verify with `helm show values external-dns/external-dns --version 1.20.0` during implementation; if so, structure adjusts but the design is otherwise unchanged.
- **SOPS handle_unencrypted_files** requires SOPS 3.9.0+. Workstation should have that already (installed during the workstation setup). Verify at implementation time.
- **`apps/longhorn/`** in the template currently has placeholders (`longhorn-crypto-global.sc.yaml`, etc.) but no canonical `release.yaml` matching the standard helm pattern. Phase 3c (Longhorn enablement) will need to author Longhorn's HelmRelease using the `deploy_new_app.sh` pattern. NOT in scope for 3a -- we just preserve the directory as-is.
- **No DNS yet.** The Dreamhost -> DO DNS delegation is set but not propagated as of file-creation time. Phase 3b blocks on it; Phase 3a does not.

## Hand-off contract to Phase 3b

After this PR merges:

- A `~/.kube/rke2-demo` kubeconfig exists on the operator workstation (from prior Ansible play).
- The operator's age key is in `~/.config/sops/age/keys.txt` and is the SOLE recipient in `.sops.yaml`.
- `flux/flux-system/sops-age.secrets.yaml` -- NOT yet committed. Phase 3b creates it (encrypted twin of the operator's age private key, used by Flux for in-cluster SOPS decryption). Chicken-and-egg solved by encrypting the age key with itself.
- `GITHUB_TOKEN` env var -- operator provides at deploy.sh runtime, not stored in the repo.
- Dreamhost -> DO DNS delegation is propagated (`dig +short NS rke2-demo.escapekey.org` returns the three DO nameservers).
