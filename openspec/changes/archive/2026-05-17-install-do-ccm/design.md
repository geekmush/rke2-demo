# Design — install-do-ccm

**Tracking issue:** [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25)

## File layout (additions + edits)

```
apps/digitalocean-cloud-controller-manager/   # new (hand-authored; no scaffolder)
├── ccm.yaml                                  # verbatim copy of upstream v0.1.67.yml
├── kustomization.yaml                        # Kustomize: ccm.yaml + secrets.yaml
└── secrets.yaml                              # SOPS-encrypted Secret (our age recipients)

ansible/roles/rke2_common/
└── defaults/main.yml                         # edit -- add rke2_kubelet_args default
ansible/roles/rke2_server/templates/
└── config.yaml.j2                            # edit -- render kubelet-arg lines
ansible/roles/rke2_agent/templates/
└── config.yaml.j2                            # edit -- render kubelet-arg lines (worker)

apps/ingress-nginx/
├── values.yaml                               # edit -- swap AWS NLB annotation for DO annotations
└── release.yaml                              # edit -- drop disableWait + "Phase 4-ish" comment

deploy.sh                                     # edit -- rke2 branch: add CCM to app_list

docs/
├── runbooks/
│   ├── install-do-ccm.md                     # new
│   └── do-bring-up.md                        # edit -- access-model section
└── diagrams/
    └── public-traffic-path.md                # new
```

No Tofu changes — CCM operates entirely via the DO API using our existing PAT.

## Install: vendored YAML, not Helm

The DO CCM project does not publish a Helm chart. The canonical install is a single self-contained manifest under `releases/digitalocean-cloud-controller-manager/v<x.y.z>.yml` in the upstream GitHub repo (RBAC + ServiceAccount + Deployment). Each release is one file; "upgrading" is overwriting that file with a newer release's content. We vendor it under `apps/digitalocean-cloud-controller-manager/ccm.yaml` so it's reconciled by Flux like everything else.

### Why not write a Helm wrapper

- The manifest is small (~200 lines) and very stable in structure between releases.
- DO doesn't ship a chart; nothing on ArtifactHub either. Writing one would mean maintaining it ourselves with no upstream sync.
- Vendoring matches what the upstream README + CCM getting-started doc both direct.
- The only thing we'd want to override (namespace, scheduling, image tag) is straightforward to handle via a Kustomize `patches:` block if needed — see "Customization" below. So far we don't need any patches.

### Customization (none today, design notes for future)

The upstream manifest hardcodes:
- `namespace: kube-system` on the Deployment and Secret references.
- `replicas: 1` and resources `requests: { cpu: 100m, memory: 50Mi }` (no limits).
- Tolerations for `node.cloudprovider.kubernetes.io/uninitialized`, `CriticalAddonsOnly`, both master + control-plane taints.
- Image pinned to `digitalocean/digitalocean-cloud-controller-manager:v0.1.67` (or whatever version we vendor).
- No `nodeSelector`. CCM runs wherever Kubernetes places it (typically a CP given the tolerations).

These are all reasonable for the test phase. **No Kustomize patches applied** in this change. If we ever need to (e.g. set a memory limit, pin to CP-only), we add a `patches:` entry to `kustomization.yaml` referencing a `patch.yaml` file. Don't fork the upstream manifest in-place — it makes diffing the next vendored release painful.

### Upgrade flow

1. Check upstream releases: <https://github.com/digitalocean/digitalocean-cloud-controller-manager/releases>.
2. Verify Kubernetes version compatibility (CCM getting-started doc has a compatibility table).
3. `curl -O https://raw.githubusercontent.com/digitalocean/digitalocean-cloud-controller-manager/master/releases/digitalocean-cloud-controller-manager/v<NEW>.yml` and replace `apps/digitalocean-cloud-controller-manager/ccm.yaml` content.
4. PR + reconcile.

## Kustomization shape

```yaml
# apps/digitalocean-cloud-controller-manager/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kube-system   # matches what ccm.yaml declares
resources:
  - ccm.yaml
  - secrets.yaml
```

The upstream manifest already sets `metadata.namespace: kube-system` on every object, so the top-level `namespace:` here is redundant-but-defensive — it'll error loudly if a future release ever drops the explicit namespace on a resource.

## Secret shape

The upstream Deployment reads:
```yaml
env:
  - name: DO_ACCESS_TOKEN
    valueFrom:
      secretKeyRef:
        name: digitalocean
        key: access-token
```

So we need `Secret/digitalocean` in `kube-system` with key `access-token`. SOPS-encrypted committed file:

```yaml
# apps/digitalocean-cloud-controller-manager/secrets.yaml (pre-SOPS form)
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean
  namespace: kube-system
type: Opaque
stringData:
  access-token: <DO_PAT>   # same value as terraform/.../secrets.enc.tfvars do_token
```

Encrypted by `./encrypt_secrets.sh` per the template convention. The kustomize-controller decrypts via `flux-system/sops-age` per the cluster's existing decryption setup (`flux/flux-system/gotk-sync.yaml` has `.spec.decryption`).

**Production-phase note**: split this into a CCM-only PAT scoped to `loadbalancer:read+write, firewall:read+write, vpc:read, droplet:read`. DO supports scoped tokens as of 2024. Out of scope for the test phase.

## Ansible: two knobs needed (v3 update)

> **Revision 3 changed this section materially.** v2 set only the kubelet-arg, which test #2 proved insufficient. v3 sets BOTH the kubelet-arg AND the RKE2-level `cloud-provider-name=external`. Both are required; neither is sufficient alone.

### Knob 1: kubelet-arg (already in main from PR #30)

`rke2_kubelet_args` in `ansible/inventory/group_vars/all/main.yml` defaults to `["cloud-provider=external"]`. Both `rke2_server` and `rke2_agent` templates render a conditional `kubelet-arg:` block from it. Purpose: tells the kubelet to expect an external cloud-provider to handle node initialization.

The original v2 reasoning was that this kubelet flag alone would produce the `node.cloudprovider.kubernetes.io/uninitialized` taint that CCM uses as its initialize-me signal. Empirically (test #2): **it doesn't, on RKE2.** RKE2's own embedded cloud-controller logic intercedes and sets `spec.providerID=rke2://<name>` at first node-join, which short-circuits the kubelet's taint logic. Once providerID is set, kubelet considers the node "initialized" and no taint is added.

### Knob 2: RKE2 cloud-provider-name (new in v3, the load-bearing one)

Add `cloud-provider-name: external` to both `rke2_server/templates/config.yaml.j2` and `rke2_agent/templates/config.yaml.j2`. This tells RKE2 NOT to set its own providerID at node-join, leaving the field empty for DO CCM to populate with `digitalocean://<droplet-id>` later.

```jinja
# ansible/roles/rke2_server/templates/config.yaml.j2 (addition, top-level)
# Disable RKE2's embedded cloud-controller so DO CCM can take over node
# initialization. Without this, RKE2 sets providerID=rke2://<name> at first
# join -- which is immutable in Kubernetes and blocks CCM from setting
# the digitalocean://<id> value its service-LB controller requires. Pairs
# with kubelet-arg=cloud-provider=external rendered above.
cloud-provider-name: external
```

Same line in `rke2_agent/templates/config.yaml.j2`. Two-line change total.

Optionally (nice-to-have): introduce `rke2_cloud_provider_name` in `group_vars/all/main.yml` defaulting to `"external"`, render through a `{% if rke2_cloud_provider_name %}` guard. Mirrors the `rke2_kubelet_args` pattern and lets Phase 4 bare-metal set it to empty to revert.

### Why both knobs

| Setting | Without it | With it |
|---|---|---|
| `cloud-provider-name: external` | RKE2 sets `providerID=rke2://<name>` → immutable → CCM rejects every node | RKE2 leaves providerID empty → CCM populates with `digitalocean://<id>` |
| `kubelet-arg: cloud-provider=external` | kubelet doesn't add the `uninitialized` taint (but this only matters if RKE2 isn't already providing initialization, which it stops doing when `cloud-provider-name=external` is set) | kubelet adds the `uninitialized` taint → general workloads cannot schedule until CCM untaints → enforces the bring-up sequencing |

Both are needed. Setting only the kubelet-arg (the v2 mistake) leaves RKE2 still in charge of providerID. Setting only `cloud-provider-name` would *probably* work for LB provisioning but produces undefined node-startup behavior because kubelet doesn't know an external CCM is incoming.

### Bring-up race vs untaint dance (correct v3 behavior)

With both knobs set on a **fresh** cluster:

1. `make play` → RKE2 starts with empty providerID + kubelet flag. Kubelet adds `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` to its node.
2. RKE2 system pods (kube-proxy, coredns, etc.) tolerate `CriticalAddonsOnly` and start normally. User workloads (cert-manager, ingress-nginx, etc.) stay `Pending`.
3. `./deploy.sh` reconciles Flux Kustomizations. CCM Kustomization succeeds (CCM Deployment tolerates the uninitialized taint). Other Kustomizations stay degraded with "pod stuck Pending" until CCM untaints.
4. CCM Deployment reaches Ready (~30s after Kustomization applies), initializes each node (calls DO API for metadata, sets `providerID=digitalocean://<id>`, adds region/zone labels), removes the `uninitialized` taint.
5. Other Kustomizations unstick within their next reconcile cycle.

Typical wall clock from `./deploy.sh` start to all-apps-Ready: 2-4 minutes.

### The fresh-cluster requirement (test-#2 takeaway, not in v2)

`spec.providerID` is **immutable** in Kubernetes once set on a Node object. An existing cluster running with `rke2://...` providerIDs cannot be migrated in-place by adding `cloud-provider-name=external` — the new flag stops RKE2 from setting providerID on *future* node joins, but doesn't clear it on existing nodes.

Two options to migrate, neither attractive:

- **A. `kubectl delete node <name>` + `systemctl restart rke2-agent` per worker**, then same for CPs one at a time. Per-node, providerID gets cleared, re-joins fresh, CCM populates. Risk: rolling CP restart can race etcd quorum loss. Untested.
- **B. Full destroy + rebuild** via `make -C terraform destroy && make apply && make play`. Clean. With PR #29's VPC retention, only droplets/LB/volumes/firewall get torn down (~5 min) and rebuilt (~10 min). Total ~15 minutes. **This is the proposal's choice.**

The runbook's "Prereqs" section calls this out explicitly so operators don't try to apply v3 in place.

### Re-running play on a cluster that already had v3 applied

Idempotent. Templates render the same config, no changes, no service restart.

### Rolling back

`rke2_cloud_provider_name: ""` (or set the knob explicitly to empty) + `rke2_kubelet_args: []` in `group_vars/all/main.yml` + `make play` re-renders `config.yaml` without both lines. RKE2 services restart. Existing nodes' `providerID=digitalocean://...` values stick around (immutable) but no longer get refreshed; CCM has nothing to do.

Note: rolling back leaves the cluster in a half-state (CCM Deployment may still be running per Flux, but kubelets behave normally). To fully roll back: also drop the CCM Kustomization from `deploy.sh` rke2 app_list + `flux/flux-system/kustomization.yaml`'s resources + reconcile (this is what PR #31 does for the test-#2 backout case).

## ingress-nginx values diff (semantic)

```yaml
controller:
  service:
    annotations:
      # REMOVE -- AWS-specific, inherited from upstream template, inapplicable on DO
      # service.beta.kubernetes.io/aws-load-balancer-type: "nlb"

      # NEW -- DO LB sizing + naming + protocol
      service.beta.kubernetes.io/do-loadbalancer-name: "do-nyc3-rke2-demo-ingress"
      service.beta.kubernetes.io/do-loadbalancer-size-unit: "1"
      service.beta.kubernetes.io/do-loadbalancer-protocol: "tcp"
      service.beta.kubernetes.io/do-loadbalancer-disable-lets-encrypt-dns-records: "true"
    externalTrafficPolicy: "Local"   # unchanged; preserved for source-IP visibility
    ipFamilies: [IPv4]                # unchanged
```

DO annotations reference: <https://docs.digitalocean.com/products/kubernetes/how-to/add-load-balancers/#load-balancer-configuration>.

## ingress-nginx release.yaml diff

```yaml
spec:
  # ... unchanged ...
  # DROP these two blocks now that CCM provisions the LB:
  #   install:  { disableWait: true }
  #   upgrade:  { disableWait: true }
  # And drop the now-stale "Revisit if we ever install DO's cloud controller"
  # comment above them.
```

## Why `tcp` protocol, not `http`/`https`

DO LB modes:
- `http` / `https`: LB terminates the TLS connection. DO has its own cert management. Health checks are HTTP-level. **Incompatible** with our cert-manager-issued certs because the LB would expect to terminate, not pass through.
- `tcp`: LB is a pure L4 forwarder. Bytes flow through to ingress-nginx, which terminates TLS using the cert-manager-issued Secret. Health check is TCP-port-open. **This is what we want.**

`tcp` mode also means client source IPs are visible to ingress-nginx via the proxy-protocol or PROXY-protocol-v2 headers (if enabled). `externalTrafficPolicy: Local` already preserves source-IP visibility via the node-local routing path; PROXY-protocol on top would add it on the LB side too, but adds an ingress-nginx config layer we don't need yet.

## deploy.sh edit

```bash
rke2)
  # was: app_list="longhorn.yaml"   (after enable-longhorn lands)
  # or:  app_list=""                 (current state)
  app_list="digitalocean-cloud-controller-manager.yaml longhorn.yaml"
  ;;
```

Ordering inside `app_list` doesn't matter — Flux Kustomization reconciliation parallelizes. List alphabetically by convention or by dependency: CCM before Longhorn is a natural grouping (network substrate first, storage second), even though neither depends on the other.

## Access-model runbook diff (`docs/runbooks/do-bring-up.md`)

Append to the "Access model" section:

```markdown
- **HTTP/80, HTTPS/443:** open to `0.0.0.0/0` on the DigitalOcean Load
  Balancer provisioned by the DO CCM for ingress-nginx. Routes to
  ingress-nginx pods inside the VPC. **This is a deliberate new public
  surface** — see [`docs/runbooks/install-do-ccm.md`](install-do-ccm.md)
  for the rationale and mitigations. Production-phase plan is to add an
  LB-level source-IP allowlist.
```

That single bullet is the "explicit user decision recorded in a runbook" CLAUDE.md requires.

## Public-traffic-path diagram outline

```mermaid
flowchart LR
  Client[Internet client]
  DNS[Public DNS<br/>escapekey.org @ DO]
  LB[DO Load Balancer<br/>do-nyc3-rke2-demo-ingress<br/>tcp/80, tcp/443]
  subgraph "VPC (10.42.0.0/20)"
    NG1[ingress-nginx<br/>worker-N]
    NG2[ingress-nginx<br/>worker-M]
    APP[App Pod<br/>via Service]
  end
  Client -->|1. Resolve canary.escapekey.org| DNS
  DNS -.A record via external-dns.-> LB
  Client -->|2. TCP/443 to LB IP| LB
  LB -->|3. TCP passthrough| NG1
  LB -->|3. TCP passthrough| NG2
  NG1 -->|4. TLS terminate (cert-manager cert)<br/>5. HTTP route by Ingress rule| APP
```

Plus a short note: how the LB selects backends (any node hosting an ingress-nginx replica, via `externalTrafficPolicy: Local`), how cert + DNS work together, and how this interacts with the existing internal LB diagram (`docs/diagrams/do-network.md` covers the kube-API path).

## Risks / open questions

- **DO LB cost** (~$12/mo) is the smallest commitment that survives `make destroy`. The CCM lifecycle ties the LB to the ingress-nginx Service — destroying the cluster + Service removes the LB. So in the test cycle, the LB only costs while the cluster is up. Confirmed in DO docs and observable post-destroy.
- **Bring-up Pending window.** Between kubelet restart (taint added) and CCM Deployment becoming Ready (taints removed), every non-tolerating workload sits Pending. Typically <60s on first bring-up. Runbook documents the expected window so it doesn't get mistaken for a failure.
- **CCM Kustomization failure leaves the cluster wedged.** If SOPS decryption fails or the DO API is unreachable, CCM can't start → can't untaint → nothing else schedules. Runbook covers triage: check Kustomization status, decrypt the Secret manually, hit the DO API from a node.
- **`providerID` on existing nodes**. CCM only sets `providerID` on nodes that don't already have one. Fresh bring-up: empty, CCM populates. Upgrade-in-place from no-CCM to CCM: existing nodes have empty providerID, CCM populates on first reconcile. No node-reschedule needed.
- **DO API rate limits.** CCM hits the DO API on every node/Service event. Default 5,000 req/hour per token; plenty for a 6-node cluster with one LB.
- **LB rename**. Changing the `do-loadbalancer-size-unit` annotation triggers an in-place resize (no IP change). Changing the `do-loadbalancer-name` annotation does NOT rename the existing LB — CCM creates a new one and orphans the old. Don't change the name annotation casually.
- **External-dns + LB IP coupling**. external-dns reads the Service's `EXTERNAL-IP` to build A records. If CCM ever fails to update the IP (DO API outage), DNS goes stale. external-dns's 10m reconcile interval bounds the staleness window.

## Hand-off contract to Phase 4 (bare-metal)

CCM is DO-specific. On bare metal it's removed entirely and replaced with one of:
- **MetalLB** (already vendored under `apps/metallb/`): assigns IPs from a pool, handles ARP/BGP.
- **kube-vip**: similar role, less BGP-heavy.

The kubelet `--cloud-provider=external` flag also goes — bare-metal kubelets don't need it. Same for the v3-added `cloud-provider-name: external` RKE2 knob. Reverting both is a single change to `group_vars/all/main.yml` (set `rke2_kubelet_args: []` and remove or empty the cloud-provider-name knob) + `make play`. As with applying v3, removing it cleanly requires a fresh cluster (the existing nodes will retain their `digitalocean://...` providerIDs, which is harmless but isn't bare-metal-flavored — the next bring-up will be clean).

The ingress-nginx values changes from this PR (DO-specific annotations) would also be reverted/replaced with MetalLB-specific configuration. Phase-4 OpenSpec proposal will own that swap. The decision to expose public HTTP/HTTPS at the cluster level (recorded in the access-model runbook) carries forward as a policy, independent of the LB implementation.
