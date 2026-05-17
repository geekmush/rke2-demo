# DigitalOcean Cloud Controller Manager — operator runbook

Enable, verify, and roll back the DO CCM on the `do-nyc3-rke2-demo` cluster.

> **CCM** = **Cloud Controller Manager**. The standard Kubernetes component that bridges cluster objects to a cloud provider's API. RKE2 on raw DO droplets doesn't ship one, which is why we install [`digitalocean/digitalocean-cloud-controller-manager`](https://github.com/digitalocean/digitalocean-cloud-controller-manager) here. With it: `Service` of `type: LoadBalancer` becomes a real DO Load Balancer, `Node` objects get `spec.providerID` + region/zone labels, and CCM untaints nodes during initialization. Without it: ingress-nginx sits at `EXTERNAL-IP <pending>` and external-dns has no LB IP to advertise.

> **Scope.** Phase 3d. Vendored manifest (no Helm chart exists). Reuses the shared full-access DO PAT for the test phase. Splits into a least-privilege CCM-only token in production — see [`openspec/changes/install-do-ccm/design.md`](../../openspec/changes/install-do-ccm/design.md).

> **Public surface.** This change opens HTTP/80 + HTTPS/443 on a new DO Load Balancer per CLAUDE.md's "anything that loosens the access model needs an explicit user decision recorded in a runbook." This document is that decision. Mitigations are listed in [`openspec/changes/install-do-ccm/proposal.md`](../../openspec/changes/install-do-ccm/proposal.md) under "Security".

## Prerequisites

> **🔒 Fresh-cluster requirement (NON-NEGOTIABLE).** This change must be applied to a freshly-joined cluster. If a cluster from a pre-v3 bring-up (anything earlier than the install-do-ccm v3 implementation merge) is running, **`make -C terraform destroy` it first** before standing up the v3 cluster. Reason: `spec.providerID` is immutable in Kubernetes, and existing nodes joined under the v2 (or no-CCM) config have `providerID=rke2://<name>` set. The v3 RKE2 knob `cloud-provider-name: external` stops RKE2 from setting providerID on *future* node-joins, but cannot clear it on existing nodes — so DO CCM continues to reject those nodes ("missing prefix `digitalocean://`") and the LB never provisions. Per-node `kubectl delete + rke2 restart` would in principle work but risks etcd quorum loss on the CPs; the destroy + rebuild path is cleaner. VPC retention per PR #29 keeps the destroy cycle quick (~5 min destroy, ~10 min rebuild).

- Cluster is up: `make -C terraform apply` succeeded, `make -C ansible play` succeeded with `failed=0`.
- Flux is bootstrapped: [`fluxcd-bootstrap.md`](fluxcd-bootstrap.md) completed.
- Both RKE2 cloud-provider knobs in place on every node (rendered automatically by `make play`):
  - `cloud-provider-name: external` (top-level in `config.yaml`) — set via `rke2_cloud_provider_name` in [`ansible/inventory/group_vars/all/main.yml`](../../ansible/inventory/group_vars/all/main.yml).
  - `kubelet-arg: ["cloud-provider=external"]` — set via `rke2_kubelet_args` in the same file.
- `~/.config/sops/age/keys.txt` exists (operator age key for SOPS decryption).

If you're standing up a fresh cluster from scratch with `enable-longhorn` + this change both in place, follow [`do-bring-up.md`](do-bring-up.md) → [`rke2-install.md`](rke2-install.md) → [`fluxcd-bootstrap.md`](fluxcd-bootstrap.md). Both RKE2 knobs land via `make play`; CCM Kustomization enablement is part of `./deploy.sh`.

## Enable

`./deploy.sh` reconciles `apps/digitalocean-cloud-controller-manager/` automatically because [`deploy.sh:222`](../../deploy.sh) adds `digitalocean-cloud-controller-manager.yaml` to the rke2 `app_list`. No manual `kubectl apply` is needed.

## Verify

### 1. Flux Kustomization is healthy

```bash
flux get kustomization -n flux-system digitalocean-cloud-controller-manager
```

Expect `READY True` within ~5 min of `./deploy.sh`'s first reconcile.

### 2. CCM Deployment is Ready

```bash
kubectl -n kube-system get deploy digitalocean-cloud-controller-manager
kubectl -n kube-system get pods -l app=digitalocean-cloud-controller-manager
```

Expect `READY 1/1` within ~1 min after the Kustomization applies. Single replica is by upstream design — CCM is stateless and re-elects on pod restart.

### 3. Nodes are untainted + initialized

```bash
# Taint should be GONE on every node (briefly present right after kubelet restart):
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'

# providerID should be populated:
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'

# Region + zone labels should be populated:
kubectl get nodes --show-labels | grep -oE 'topology.kubernetes.io/(region|zone)=[a-z0-9]+'
```

`providerID` should be `digitalocean://<droplet-id>` for every node. Region should be `nyc3`.

### 4. Ingress-nginx Service got a real EXTERNAL-IP

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

Expect a public IPv4 in the `EXTERNAL-IP` column within ~2 min of CCM Ready. Before this PR, that column stayed `<pending>` forever.

### 5. DO Networking → Load Balancers shows the new LB

In the DO control panel:

- Name: `do-nyc3-rke2-demo-ingress`
- Size: `lb-small` (1 node)
- Forwarding rules: `tcp/80 → tcp/80`, `tcp/443 → tcp/443`
- Health check: TCP on the ingress-nginx node port
- Attached droplets: every node hosting an ingress-nginx replica (workers, given `externalTrafficPolicy: Local`).

### 6. End-to-end canary

Apply the same canary Ingress from [`dns-migration-to-do.md`](dns-migration-to-do.md) step 6 (http-echo + Deployment + Service + Ingress under `canary.escapekey.org`). With CCM up, three things happen that didn't happen on the pre-CCM bring-up:

- external-dns creates an `A` record for `canary.escapekey.org` at DO pointing at the LB IP (`kubectl -n external-dns logs deploy/external-dns -f`).
- cert-manager issues a real LE cert via DNS-01 (same as before).
- `curl https://canary.escapekey.org` returns the canary payload from outside the VPC (the previous test was DNS-01-cert-only because the LB had no IP).

Verify:

```bash
dig +short A canary.escapekey.org @ns1.digitalocean.com
# expect the LB EXTERNAL-IP from step 4

curl -v https://canary.escapekey.org 2>&1 | grep -E "(issuer|HTTP/|cert+dns)"
# expect: HTTP/2 200, "cert+dns canary OK" payload, issuer "C=US, O=Let's Encrypt, CN=R<N>"
```

Tear down the canary:

```bash
kubectl delete ingress,svc,deploy dns-cert-canary -n default
kubectl delete certificate,secret canary-escapekey-tls -n default
```

external-dns will remove the DNS A record on next reconcile (`policy: sync`).

## Expected pending-state window on fresh bring-up

The kubelet flag `--cloud-provider=external` causes every kubelet to taint its node with `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` at startup. The CCM Deployment tolerates that taint (built into the upstream manifest), so it lands fine. Other workloads (cert-manager, ingress-nginx, longhorn) do NOT tolerate it — they sit `Pending` until CCM initializes each node and removes the taint.

Typical timing on a fresh bring-up:

| Time | Event |
|---|---|
| `t+0` | `make play` finishes; nodes tainted. |
| `t+0..60s` | `./deploy.sh` reconciles all Flux Kustomizations. Most pods stuck `Pending`. CCM Kustomization applies first (tolerates taint). |
| `t+60..90s` | CCM Deployment Ready; starts initializing nodes. |
| `t+90..120s` | All nodes untainted, providerID + zone labels populated. Other Pending pods schedule. |

If pods are still `Pending` after 5 min and CCM logs show errors, see Triage below.

## Triage if the cluster gets wedged in `Pending`

The most painful failure mode is "CCM Kustomization can't reconcile → can't untaint → no other workloads schedule." Quick checks:

```bash
# Is the Kustomization happy?
flux get kustomization -n flux-system digitalocean-cloud-controller-manager
flux get helmrelease -A   # secondary signal -- other apps stuck Pending

# Can SOPS decrypt the secret?
sops -d apps/digitalocean-cloud-controller-manager/secrets.yaml | head -5
# Should print the manifest. If "no key could decrypt", the cluster's
# flux-system/sops-age Secret doesn't match the operator's age key OR
# .sops.yaml recipients drifted.

# Did CCM actually start? (May not have, if Kustomization is failing.)
kubectl -n kube-system get pods -l app=digitalocean-cloud-controller-manager
kubectl -n kube-system logs deploy/digitalocean-cloud-controller-manager --tail=50

# Can CCM reach the DO API?
kubectl -n kube-system exec deploy/digitalocean-cloud-controller-manager -- \
  wget -qO- --header="Authorization: Bearer $(kubectl -n kube-system get secret digitalocean -o jsonpath='{.data.access-token}' | base64 -d)" \
  https://api.digitalocean.com/v2/account
# expect a 200 JSON response with account info
```

Common causes:

- **Stale SOPS decryption Secret in cluster.** Apply the plaintext via `sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -`. See issue #24 / fix in `fc76c27`.
- **DO PAT expired or scoped wrong.** Rotate via `sops apps/digitalocean-cloud-controller-manager/secrets.yaml`, commit + push, reconcile.
- **RKE2 cloud-provider knobs didn't reach the node.** `ssh root@<node-public-ip> 'grep -A2 cloud-provider /etc/rancher/rke2/config.yaml'`. Should show **both** `cloud-provider-name: "external"` AND `kubelet-arg: - "cloud-provider=external"`. If either is missing, re-run `make -C ansible play`.

### Test-#2 failure mode: CCM Ready but does nothing (rke2:// providerID)

Test #2 on 2026-05-17 confirmed an insidious failure mode that *looks* healthy at first glance: CCM Deployment is Running and the Flux Kustomization reports Ready=True, but `EXTERNAL-IP` on ingress-nginx stays `<pending>` forever and the canary never gets a public IP. The smoking gun is in CCM's logs:

```
E ... node_controller.go:288] Error getting instance metadata for node addresses:
    determining droplet ID from providerID: provider ID "rke2://do-nyc3-rke2-demo-cp-01"
    is missing prefix "digitalocean://"

E ... controller.go:302] "Unhandled Error" err="error processing service
    ingress-nginx/ingress-nginx-controller (retrying with exponential backoff):
    failed to ensure load balancer: failed to build load-balancer request:
    no ready nodes available for load balancer"
```

This means `cloud-provider-name: external` was NOT in effect at the time the cluster first joined nodes (so RKE2's embedded cloud-controller set `providerID=rke2://...`, which is immutable). Verify the actual node state:

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
# Bad:  rke2://do-nyc3-rke2-demo-cp-01
# Good: digitalocean://571xxxxxx
```

**Recovery: this cluster cannot be salvaged in place.** Run `make -C terraform destroy` and bring up a fresh cluster from scratch — by then v3's RKE2 knob is in `group_vars/all/main.yml` and the first node-join will leave providerID empty for CCM to populate. The VPC stays per #29, so destroy + rebuild is ~15 min total.

## Rollback

Two reasons to roll back: CCM is causing problems, or moving the cluster to bare metal (Phase 4).

```bash
# 1. Drop CCM from the Flux app_list:
sed -i 's/"digitalocean-cloud-controller-manager.yaml"/""/' deploy.sh
git commit -am "Disabling CCM"
git push

# 2. Reconcile -- Flux removes the Kustomization, CCM Deployment gone:
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# 3. Remove the kubelet flag from group_vars + re-render config:
yq -i '.rke2_kubelet_args = []' ansible/inventory/group_vars/all/main.yml
git commit -am "Removing cloud-provider=external from kubelets"
git push
cd ansible && make play
```

After (1+2), the DO LB attached to the ingress-nginx Service is destroyed by CCM during its own teardown (the Service drops the `loadBalancer` status field and CCM's controller-runtime tears down the corresponding DO resource).

After (3), kubelets restart without the `external` flag; nodes come up untainted; CCM doesn't run. ingress-nginx Service Type=LoadBalancer goes back to `EXTERNAL-IP <pending>` (no controller to provision it).

## Cost

| Item | Cost (NYC3) |
|---|---|
| `lb-small` DO Load Balancer, while cluster is up | ~$12/mo (~$0.018/hour) |
| `make destroy` (CCM deletes the LB as part of ingress-nginx Service teardown) | $0 |

LB doesn't survive `make destroy` because CCM tears it down when the Service is gone. So in the test cycle, the only LB cost is during active sessions.

## See also

- [`openspec/changes/install-do-ccm/proposal.md`](../../openspec/changes/install-do-ccm/proposal.md) — why + the public-surface decision + decisions locked in.
- [`openspec/changes/install-do-ccm/design.md`](../../openspec/changes/install-do-ccm/design.md) — file-level shape + bring-up race walkthrough.
- [`docs/diagrams/public-traffic-path.md`](../diagrams/public-traffic-path.md) — request flow from internet → DO LB → ingress-nginx → app.
- [`docs/runbooks/dns-migration-to-do.md`](dns-migration-to-do.md) — canary Ingress used in step 6.
- [`docs/runbooks/fluxcd-bootstrap.md`](fluxcd-bootstrap.md) — what `./deploy.sh` does.
