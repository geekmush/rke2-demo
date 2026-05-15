# Design — add-fluxcd-bootstrap

**Tracking issue:** [#16](https://github.com/geekmush/rke2-demo/issues/16)

## sops-age secret bootstrap (chicken-and-egg solved)

Flux's `kustomize-controller` decrypts SOPS-encrypted Kubernetes manifests at reconciliation time. It needs the operator's age **private** key, materialized as a Kubernetes Secret named `sops-age` (default name) in the `flux-system` namespace.

The chicken-and-egg: we want to deliver this Secret via the same SOPS-encrypted git workflow as everything else, but Flux can't read SOPS-encrypted files until it has the sops-age Secret installed. Resolution: encrypt the sops-age Secret **with the operator's age key** (self-referential), and have `deploy.sh` apply it cluster-side via `sops -d ... | kubectl apply` **before** `flux bootstrap`.

Flow:

```
operator workstation                                    cluster
─────────────────────                                  ─────────
1. operator runs deploy.sh
                                                       (empty cluster)
2. sops -d flux/flux-system/sops-age.secrets.yaml \
     | kubectl apply -f -                              → flux-system/sops-age Secret created
                                                          (contains operator's age private key)
3. flux bootstrap github ...                           → 6 Flux controllers installed
                                                          gotk-components.yaml + gotk-sync.yaml
                                                          generated, committed, pushed
4. patch gotk-sync.yaml: spec.decryption added
                                                       → kustomize-controller reads
5. apps appended to                                       sops-age Secret to decrypt
   flux/flux-system/kustomization.yaml                    every *.secrets.yaml in the tree
                                                       → Flux reconciles core_apps:
                                                            cert-manager
                                                            ingress-nginx
                                                            external-dns
                                                            cert-manager-custom-resources
                                                            image* (empty placeholder Kustomizations)
                                                            sops-age.secrets (no-op, already applied)
```

The `sops-age.secrets.yaml` file shape (after SOPS encryption):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: sops-age
  namespace: flux-system
type: Opaque
stringData:
  age.agekey: ENC[AES256_GCM,...]    # the operator's full ~/.config/sops/age/keys.txt content
sops:
  age:
    - recipient: age1s8ed4qr4k7hvwu6mx5z80prurzz2wcq4gk2ujyh8w75ssaxy44xq8pzjdk
      enc: |-
        -----BEGIN AGE ENCRYPTED FILE-----
        ...
```

`age.agekey` is the standard Secret key Flux's `kustomize-controller` looks for (configurable in gotk-sync.yaml but we use the default).

## Self-signed ClusterIssuer

`apps/cert-manager-custom-resources/selfsigned-clusterissuer.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
```

Trivial spec. No external dependencies. cert-manager's controller creates a Secret containing a Certificate signed by an in-memory CA for each issuance request.

Use cases:

- **Phase 3b verification** -- issue a test Certificate against this issuer; confirm cert-manager's full path (controller + webhook + cainjector) works without depending on ACME / DNS.
- **Long-term** -- cluster-internal mTLS, dev/staging endpoints, anything that doesn't need a publicly-trusted CA.

`apps/cert-manager-custom-resources/kustomization.yaml`'s `resources` list grows by one entry: `selfsigned-clusterissuer.yaml`.

## `variables.sh` workaround for plaintext keys.txt

Template ships:

```bash
export SOPS_AGE_KEY=$(age -d "${sops_dir}/keys.txt")
```

Assumes `keys.txt` is age-passphrase-encrypted (template author's setup). Our `~/.config/sops/age/keys.txt` is plaintext (created with `age-keygen -o ~/.config/sops/age/keys.txt` per the workstation runbook -- no passphrase wrapping).

Replace with:

```bash
export SOPS_AGE_KEY_FILE="${sops_dir}/keys.txt"
```

SOPS reads the file directly via the standard env var. No bash-level decryption ceremony, no passphrase prompts. Works for `sops -d` invocations and for the Flux SOPS integration alike.

This is candidate Phase 5 upstream contribution: "support plaintext keys.txt" as a `variables.sh` option.

## Temporary Longhorn drop in deploy.sh

`deploy.sh`'s `rke2)` case after Phase 3a:

```bash
rke2)
  app_list="longhorn.yaml"
  ;;
```

After Phase 3b:

```bash
rke2)
  # TEMPORARY: longhorn dropped for Phase 3b to keep the cluster state clean
  # while we validate the Flux + core_apps bring-up. Phase 3c restores
  # `longhorn.yaml` here alongside the longhorn-config fixes (replacing
  # the template author's upstream-encrypted secrets with cluster-specific
  # ones; pointing Longhorn at the per-worker /dev/disk/by-id/scsi-0DO_Volume_*
  # devices from the Tofu output worker_longhorn_devices).
  app_list=""
  ;;
```

Phase 3c reverts to `app_list="longhorn.yaml"` in the same single line, alongside the cluster-side longhorn config work.

## deploy.sh execution flow (annotated)

Reference for the runbook. The script does roughly:

```bash
1. cd ${SCRIPT_DIR}
2. source variables.sh                        # loads cluster_name, KUBECONFIG, SOPS_AGE_KEY_FILE, tool versions
3. # download tools into bin/ if not present
   for tool in kubectl flux sops yq; do ... ; done
4. # apply the sops-age Secret to flux-system namespace
   kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
   sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -
5. # bootstrap Flux against the consumer's GitHub repo
   flux bootstrap github \
     --owner="${git_owner}" \
     --repository="${git_repo}" \
     --path="${flux_path}" \
     --read-write-key \
     --components-extra=image-reflector-controller,image-automation-controller
6. # patch gotk-sync.yaml for SOPS decryption
   yq -i '.spec.decryption = {"provider": "sops", "secretRef": {"name": "sops-age"}}' \
     flux/flux-system/gotk-sync.yaml
   git add flux/flux-system/gotk-sync.yaml
   git commit -nm "Enabling SOPS decryption"
7. # enable core_apps + per-platform app_list
   for app in $core_app_list $app_list; do
     yq -i ".resources += [\"${app}\"] | .resources |= unique" flux/flux-system/kustomization.yaml
   done
   git add flux/flux-system/kustomization.yaml
   git commit -nm "Enabling Flux Kustomizations"
8. git push                                   # operator-side push; the bootstrap deploy key would also work
9. # encrypt any *.decrypted files left over from the bootstrap
   ./encrypt_secrets.sh
```

(Exact ordering and step boundaries may differ slightly in the actual `deploy.sh`; the runbook will be precise.)

## Expected post-bootstrap repo state

New files committed by `flux bootstrap` (operator-machine-authored, but the runbook documents them as expected):

- `flux/flux-system/gotk-components.yaml` -- Flux controllers + CRDs static manifest. Replaces our 1-line stub.
- `flux/flux-system/gotk-sync.yaml` -- Flux's self-sync `GitRepository` + `Kustomization` resources. Replaces our 1-line stub. After `deploy.sh`'s yq patch, includes the `spec.decryption` block.

New flux-system Kustomization entries in `flux/flux-system/kustomization.yaml.resources` (~8 added):

- cert-manager-custom-resources.yaml
- cert-manager.yaml
- external-dns.yaml
- imagepolicies.yaml
- imagerepositories.yaml
- imageupdateautomation.yaml
- ingress-nginx.yaml
- sops-age.secrets.yaml

(No `longhorn.yaml` -- Path B.)

Commits authored by `fluxcdbot@users.noreply.github.com`:

1. `Add Flux v2.6.4 component manifests` (gotk-components.yaml)
2. `Add Flux sync manifests` (gotk-sync.yaml)
3. `Enabling SOPS decryption` (gotk-sync.yaml patch)
4. `Enabling Flux Kustomizations` (kustomization.yaml resource appends)

(Names approximate; based on the template's deploy.sh and observed flux bootstrap output.)

## Verification matrix

Run from the operator workstation with the kube tunnel open + KUBECONFIG set:

| What | How | Expected |
|---|---|---|
| Flux controllers | `kubectl -n flux-system get deploy` | 6 deployments, all `Ready 1/1` |
| Flux Kustomizations | `flux get kustomizations` | All `Ready=True`. `cert-manager` may be slow on first reconcile (~60s). |
| cert-manager pods | `kubectl -n cert-manager get pods` | 3 pods Ready: cert-manager, webhook, cainjector |
| ingress-nginx | `kubectl -n ingress-nginx get pods,svc` | controller pod Ready; Service in `<pending>` external-IP (no DO cloud controller; OK) |
| external-dns | `kubectl -n external-dns get pods` + `logs` | Pod Ready; logs show "Connection to DigitalOcean API successful" or similar |
| ClusterIssuers | `kubectl get clusterissuers` | Two: `letsencrypt` (`Ready=False` -- DNS-01 fails, expected) and `selfsigned` (`Ready=True`) |
| Test cert | apply the test Certificate via selfsigned; `kubectl get cert test-selfsigned -o wide` | Ready=True within 60s, `test-selfsigned-tls` Secret produced |

## Risks / open questions

- **`flux bootstrap` failure mid-flight.** Idempotent on retry, but if the deploy key was half-created on GitHub we may need to clean it up via the web UI before retry. Runbook will note.
- **`SOPS_AGE_KEY_FILE` upstream divergence.** Template assumes age-encrypted keys.txt. Our edit makes Phase 3a + 3b diverge cleanly. Phase 5 candidate to upstream as a `variables.sh` switch / both-modes-supported approach.
- **ingress-nginx Service in `<pending>`** indefinitely until either we provision a DO LB or flip Service type to ClusterIP. Acceptable Phase 3b state (no real ingress traffic yet); will revisit when Phase 3c or later adds app ingress.
- **`flux bootstrap`-authored commits on main bypass PR review.** Standard FluxCD pattern. The deploy key on the repo is RW-scoped. Worth flagging in the runbook so future changes via Flux are not surprises.
- **Phase 3b runbook test cert leaves a Secret behind.** The test Certificate produces `default/test-selfsigned-tls`. The verification steps should include `kubectl delete certificate test-selfsigned` (which cleans up the secret) before declaring done. Will include.
- **DNS not propagated.** `letsencrypt` ClusterIssuer is degraded; external-dns runs but does nothing visible. Documented as expected. Phase 3b doesn't block on DNS.
- **`apps/*` `helm_secrets.yaml.decrypted` files become `helm_secrets.yaml` (encrypted) when `encrypt_secrets.sh` runs.** Phase 3b's `deploy.sh` runs this at the end. We'll see ~6 new committed `helm_secrets.yaml` files in the post-deploy state.

## Hand-off contract to Phase 3c

After Phase 3b:

- Flux is reconciling the repo's `flux/flux-system/` kustomization with SOPS decryption.
- cert-manager, ingress-nginx, external-dns are running and ready to support other apps.
- A working sops-age Secret in `flux-system` namespace; Flux decrypts new `secrets.yaml` files added via PR automatically.
- `apps/longhorn/` exists but is NOT in `flux/flux-system/kustomization.yaml.resources`.

Phase 3c then:

- Replaces upstream-author-encrypted `apps/longhorn/*.secrets.yaml` placeholders with cluster-specific ones (or removes them if not needed).
- Edits `apps/longhorn/values.yaml` to point at the per-worker block-storage devices (`worker_longhorn_devices` Tofu output).
- Restores `deploy.sh`'s `rke2)` case to `app_list="longhorn.yaml"`.
- Re-runs `deploy.sh` (idempotent; adds longhorn to kustomization.yaml.resources).
- Flux reconciles longhorn; PVCs become provisionable.
