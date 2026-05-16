# FluxCD bootstrap runbook

End-to-end operator procedure for running `deploy.sh` and reconciling the FluxCD core platform apps onto the cluster.

> **Scope.** Phase 3b: bootstrap FluxCD + reconcile cert-manager, ingress-nginx, external-dns, cert-manager-custom-resources, and the Flux image-automation Kustomizations. **Longhorn is intentionally NOT enabled in this phase** -- restored in Phase 3c.

## Prerequisites

Operator workstation has:

- Everything from [`linux-workstation-setup.md`](linux-workstation-setup.md) and [`do-bring-up.md`](do-bring-up.md).
- The RKE2 cluster is up: `make -C terraform output` shows 3 CPs + 3 workers, internal LB at `10.42.0.41` (or wherever).
- `make -C ansible play` is idempotent (reports `changed=0`) -- proves the cluster + kubeconfig are healthy.
- The kube SSH tunnel can be opened (`make -C ansible tunnel` works in another terminal).
- `~/.config/sops/age/keys.txt` exists and is the operator's plaintext age key (per [`linux-workstation-setup.md`](linux-workstation-setup.md) step 8).

DigitalOcean side:

- DO API token in `terraform/environments/do-test/secrets.enc.tfvars` has full-access scopes (already verified). cert-manager and external-dns reuse this token via `apps/external-dns/secrets.yaml` and `apps/cert-manager-custom-resources/digitalocean-dns.secrets.yaml`.

DNS:

- `escapekey.org` is hosted at DigitalOcean (whole zone, not a delegated subdomain) per [`dns-migration-to-do.md`](dns-migration-to-do.md). The DO PAT in `digitalocean-dns.secrets.yaml` already has DNS write authority on the zone, so `external-dns` and the `letsencrypt` DNS-01 ClusterIssuer work end-to-end. The `selfsigned` ClusterIssuer remains as a no-DNS-required fallback for cert-manager-works verification.

GitHub:

- A fresh fine-grained Personal Access Token with `Administration: Read and write` + `Contents: Read and write` permissions on `geekmush/do-nyc3-rke2-demo`. Single-use during bootstrap; consider a 7-day expiry. Generate at https://github.com/settings/tokens?type=beta.
- **Do not paste the token into chat or commit it anywhere.** Read into a shell variable via `read -s` (suppresses echo) so it doesn't enter shell history.

## One-time setup

### 1. Stage the GitHub PAT in env

In the same shell you'll run `deploy.sh` from:

```bash
read -s GITHUB_TOKEN
# (paste the PAT, press enter -- nothing echoes)
export GITHUB_TOKEN
```

Verify scope (does not reveal the token):

```bash
curl -sS -H "Authorization: token $GITHUB_TOKEN" https://api.github.com/repos/geekmush/do-nyc3-rke2-demo \
  | jq '{permissions: .permissions}'
# expected: admin/push/pull all true
```

### 2. Source `variables.sh`

```bash
source variables.sh
echo "cluster_name=$cluster_name"
echo "KUBECONFIG=$KUBECONFIG"
echo "SOPS_AGE_KEY_FILE=$SOPS_AGE_KEY_FILE"
```

Expected:

```
cluster_name=do-nyc3-rke2-demo
KUBECONFIG=/home/<you>/.kube/do-nyc3-rke2-demo
SOPS_AGE_KEY_FILE=/home/<you>/.config/sops/age/keys.txt
```

### 3. Open the kube tunnel (separate terminal)

```bash
make -C ansible tunnel
```

Leave running.

### 4. Sanity-check cluster reachability from the bootstrap shell

```bash
kubectl get nodes
# expected: 3 CP + 3 worker Ready
```

If this errors, the tunnel isn't up or KUBECONFIG isn't pointed correctly. Fix before proceeding.

## Bootstrap

```bash
./deploy.sh
```

What happens, narrated:

1. **Tool fetch.** `kubectl`, `flux`, `sops`, `yq` downloaded into `bin/` (versions pinned in `variables.sh`). Skipped if already present.
2. **sops-age Secret install.** `sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -` -- the operator's age private key lands in `flux-system` namespace as a Secret named `sops-age`. Flux's `kustomize-controller` reads this Secret to decrypt every other `*.secrets.yaml` in the repo at reconciliation time.
3. **`flux bootstrap github`.** Installs the 6 Flux controllers cluster-side, creates a deploy key on `geekmush/do-nyc3-rke2-demo`, generates `flux/flux-system/gotk-components.yaml` + `gotk-sync.yaml`, commits + pushes to `main` via the deploy key.
4. **Patch `gotk-sync.yaml`** -- adds `spec.decryption: {provider: sops, secretRef: {name: sops-age}}`. Commits the patch.
5. **Enable apps** -- appends `core_app_list` entries to `flux/flux-system/kustomization.yaml`'s `.resources`. For us: cert-manager-custom-resources, cert-manager, external-dns, imagepolicies, imagerepositories, imageupdateautomation, ingress-nginx, sops-age.secrets. **No longhorn** (rke2 case is intentionally empty for Phase 3b).
6. **`encrypt_secrets.sh`** -- re-encrypts any `*.decrypted` files left in the working tree. Useful if you've been editing `helm_secrets.yaml.decrypted` placeholders.

Expected duration: 2-4 minutes. The slowest part is the initial Helm chart pulls for cert-manager + ingress-nginx + external-dns.

Expected new commits on `main` (authored by `fluxcdbot@users.noreply.github.com`):

| # | Subject (approximate) | Source |
|---|---|---|
| 1 | `Add Flux v2.6.4 component manifests` | `flux bootstrap` writes gotk-components.yaml |
| 2 | `Add Flux sync manifests` | `flux bootstrap` writes gotk-sync.yaml |
| 3 | `Enabling SOPS decryption` | `deploy.sh` patches gotk-sync.yaml |
| 4 | `Enabling Flux Kustomizations` | `deploy.sh` modifies flux/flux-system/kustomization.yaml |

These commits **bypass PR review** -- pushed directly to `main` via the deploy key. This is the standard FluxCD pattern. Pull them locally with `git pull` once bootstrap finishes.

## Verification

Run from the bootstrap shell (with KUBECONFIG + tunnel open).

### Flux controllers

```bash
kubectl -n flux-system get deploy
```

Expected: 6 deployments, all `Ready 1/1`:

- `source-controller`
- `kustomize-controller`
- `helm-controller`
- `notification-controller`
- `image-reflector-controller`
- `image-automation-controller`

If any deployment is `0/1`, describe it and inspect logs:

```bash
kubectl -n flux-system describe deploy <name>
kubectl -n flux-system logs -l app=<name> --tail=50
```

### Flux Kustomizations

```bash
flux get kustomizations
```

Expected: every entry shows `READY=True`. The `cert-manager` reconciliation may take up to 90s on first apply (Helm chart pull + CRD install + webhook readiness).

If something is `Ready=False`, drill in:

```bash
kubectl -n flux-system describe kustomization <name>
```

### cert-manager pods

```bash
kubectl -n cert-manager get pods
```

Expected: 3 pods Ready:

- `cert-manager-...` (controller)
- `cert-manager-webhook-...`
- `cert-manager-cainjector-...`

### ingress-nginx

```bash
kubectl -n ingress-nginx get pods,svc
```

Expected:

- `ingress-nginx-controller-...` pod Ready.
- `ingress-nginx-controller` Service of type `LoadBalancer` with EXTERNAL-IP `<pending>`. **Expected** -- we don't run DO's cloud-controller-manager, so no external LB is provisioned. Cluster-internal ingress traffic still works through this Service.

### external-dns

```bash
kubectl -n external-dns get pods
kubectl -n external-dns logs deploy/external-dns --tail=30
```

Expected:

- Pod Ready.
- Logs show successful DO API authentication (no "401 Unauthorized" or "domain not found"). The logs may also include "no records found" or similar -- expected until the Dreamhost DNS delegation propagates and there are real ingress resources to advertise.

### ClusterIssuers

```bash
kubectl get clusterissuers
```

Expected: TWO entries.

| NAME | READY | REASON |
|---|---|---|
| `letsencrypt` | False | ACME setup blocked on DNS propagation -- expected. The issuer is registered but cannot complete the first ACME order. |
| `selfsigned` | True | In-memory CA, no external deps. |

### Test cert via the self-signed issuer

This is the "cert-manager works end-to-end" verification.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-selfsigned
  namespace: default
spec:
  secretName: test-selfsigned-tls
  issuerRef:
    name: selfsigned
    kind: ClusterIssuer
  dnsNames:
    - test.local
EOF
```

Within 60 seconds:

```bash
kubectl get certificate test-selfsigned -o jsonpath='{.status.conditions}' | jq .
# expected: a Ready=True condition

kubectl get secret test-selfsigned-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
# expected:
#   subject=CN = test.local
#   issuer=CN = test.local
```

Clean up:

```bash
kubectl delete certificate test-selfsigned
kubectl delete secret test-selfsigned-tls 2>/dev/null
```

## Troubleshooting

### `flux bootstrap` fails partway

`flux bootstrap` is idempotent on retry, **but** if the run partially created the deploy key on GitHub, retry can fail with "deploy key already exists." Fix:

1. https://github.com/geekmush/do-nyc3-rke2-demo/settings/keys -- delete the half-created key (look for one named `flux` or similar).
2. `git pull` -- pick up any flux-authored commits that did land.
3. Re-run `./deploy.sh`.

### `sops -d flux/flux-system/sops-age.secrets.yaml` fails

Means SOPS can't decrypt with your age key. Common causes:

- `SOPS_AGE_KEY_FILE` not pointing at the right file (`echo $SOPS_AGE_KEY_FILE`).
- `~/.config/sops/age/keys.txt` was rotated/replaced; the file's recipient no longer matches your current key.
- The age recipient in `.sops.yaml` is stale -- check `git show HEAD:.sops.yaml` against your current key.

To recover, you'd need either the original age private key the file was encrypted with, or rebuild the secret from scratch (re-author `flux/flux-system/sops-age.secrets.yaml` and commit).

### sops-age Secret missing from `flux-system` namespace

If `kubectl -n flux-system get secret sops-age` returns NotFound after running `deploy.sh`:

```bash
sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -
```

Manual fallback to step 2 of the bootstrap.

### `ingress-nginx-controller` Service in `<pending>` forever

Expected (see above). If you need an actual external IP, options:

- Install DO's cloud-controller-manager (separate change).
- Switch the Service to `NodePort` or `ClusterIP` via a kustomize patch in `apps/ingress-nginx/`.
- Provision an application-tier DO LB explicitly (future Phase).

### Test Certificate hangs at `Ready=False`

```bash
kubectl describe certificate test-selfsigned
kubectl -n cert-manager logs -l app.kubernetes.io/name=cert-manager --tail=50
```

Common causes:

- cert-manager pods not actually Ready -- check `kubectl -n cert-manager get pods`.
- cert-manager webhook unreachable -- usually a flannel/CNI hiccup; restarting cert-manager pods fixes.

## Rollback

If Phase 3b goes wrong and you need to back out:

```bash
# revert local file commits
git reset --hard <pre-bootstrap commit>

# remove Flux from the cluster
flux uninstall --silent

# remove the sops-age Secret
kubectl -n flux-system delete secret sops-age
kubectl delete namespace flux-system
```

The cluster goes back to RKE2-only (no Flux, no cert-manager, no ingress-nginx). Tofu / Ansible state unaffected.

The repo's `main` branch still has the fluxcdbot commits. They're harmless -- just an unused `flux/flux-system/gotk-*.yaml`. Either leave them or revert with a new commit.

## What's next (Phase 3c)

Once Phase 3b is verified, Phase 3c:

- Replaces the upstream-author-encrypted `apps/longhorn/*.secrets.yaml` placeholders with cluster-specific ones (or removes them outright if Longhorn doesn't need them).
- Edits `apps/longhorn/values.yaml` to point at the per-worker block-storage devices (`worker_longhorn_devices` Tofu output).
- Restores `deploy.sh`'s `rke2)` case to `app_list="longhorn.yaml"`.
- Re-runs `./deploy.sh` -- adds longhorn to `flux/flux-system/kustomization.yaml.resources`.
- Verifies Longhorn pods come up; PVCs become provisionable.

## See also

- [`docs/runbooks/do-bring-up.md`](do-bring-up.md) -- DO substrate
- [`docs/runbooks/rke2-install.md`](rke2-install.md) -- RKE2 cluster install via Ansible
- [`docs/runbooks/secrets.md`](secrets.md) -- SOPS + age operator setup
- [`docs/diagrams/rke2-topology.md`](../diagrams/rke2-topology.md) -- cluster topology
- [`openspec/changes/archive/2026-05-15-add-fluxcd-template-vendor/`](../../openspec/changes/archive/2026-05-15-add-fluxcd-template-vendor/) -- Phase 3a vendoring design
- [`openspec/changes/add-fluxcd-bootstrap/`](../../openspec/changes/add-fluxcd-bootstrap/) -- this change
- Upstream template README archived at [`docs/upstream/fluxcd-template-README.md`](../upstream/fluxcd-template-README.md)
