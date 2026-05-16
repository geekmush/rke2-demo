# Design — install-do-ccm

**Tracking issue:** [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25)

## File layout (additions + edits)

```
apps/digitalocean-cloud-controller-manager/   # new (scaffolded by deploy_new_app.sh)
├── helmrepo.yaml
├── kustomization.yaml
├── kustomizeconfig.yaml
├── namespace.yaml
├── release.yaml
├── secrets.yaml                              # SOPS-encrypted (our age recipients)
└── values.yaml

apps/ingress-nginx/
├── values.yaml                               # edit -- swap AWS NLB annotation for DO annotations
└── release.yaml                              # edit -- drop disableWait + the "Phase 4-ish" comment

deploy.sh                                     # edit -- rke2 branch: add CCM to app_list

docs/
├── runbooks/
│   ├── install-do-ccm.md                     # new
│   └── do-bring-up.md                        # edit -- access-model section
└── diagrams/
    └── public-traffic-path.md                # new
```

No Tofu changes — CCM operates entirely via the DO API using our existing PAT.

## CCM chart + values

DigitalOcean publishes the chart at `https://charts.digitalocean.com/`. Pin a specific version at scaffold time. The chart's only required value is the API token; everything else has reasonable defaults.

`apps/digitalocean-cloud-controller-manager/values.yaml` (committed plaintext):

```yaml
# Cluster identity surfaces in DO-side annotations and tags. Matches cluster_name.
clusterName: do-nyc3-rke2-demo

# CCM watches every node + every LoadBalancer Service. Single replica is fine
# for a 6-node test cluster; HA isn't necessary at this scale (CCM is
# stateless and re-elects on pod restart).
replicaCount: 1

# Keep CCM off worker storage I/O paths -- it's a control-plane concern.
# RKE2 doesn't taint CPs by default, but we tolerate node-role taints if
# they get added later.
tolerations:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule
nodeSelector:
  node-role.kubernetes.io/control-plane: "true"

resources:
  requests: { cpu: 50m,  memory: 64Mi }
  limits:   { memory: 128Mi }
```

`apps/digitalocean-cloud-controller-manager/secrets.yaml` (SOPS-encrypted):

```yaml
# After scaffolding, the SOPS-encrypted form of:
apiVersion: v1
kind: Secret
metadata:
  name: digitalocean
  namespace: digitalocean-cloud-controller-manager
type: Opaque
stringData:
  access-token: <DO_PAT>   # same full-access PAT used by tofu / external-dns / cert-manager
```

The CCM chart looks for a Secret named `digitalocean` with key `access-token` by default. Matching that default avoids extra `existingSecret` plumbing in values.yaml.

**Production-phase note**: split this into a CCM-only PAT with scopes `loadbalancer:read+write, firewall:read+write, vpc:read, droplet:read` (DO scoped tokens support per-resource read/write splits as of 2024). Out of scope for the test phase.

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

Keeping the disableWait blocks would still work; dropping them is the more accurate signal. If CCM is ever uninstalled (Phase 4 bare-metal: replaced by MetalLB or similar), the disableWait blocks come back as part of that change.

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
- **CCM reconcile race vs ingress-nginx Service create.** If CCM starts after the Service already exists (which it will on first install), CCM picks it up and provisions the LB. If the Service is created BEFORE CCM is Ready (which happens when ingress-nginx HelmRelease reconciles before CCM HelmRelease), the Service sits at `<pending>` until CCM catches up — usually within seconds because the controller polls. Not a functional issue.
- **`providerID` on existing nodes**. CCM only sets `providerID` on nodes that don't already have one (it's append-only). Our existing nodes have `providerID` empty (RKE2 default with no CCM). CCM will populate them on first reconcile. Verified pattern; no node-reschedule needed.
- **DO API rate limits.** CCM hits the DO API on every node/Service event. The default DO API limit (5,000 req/hour per token) is plenty for a 6-node cluster with one LB. Worth monitoring as cluster grows.
- **Replacing the LB**. Changing the `do-loadbalancer-size-unit` annotation triggers an in-place LB resize (no IP change). Changing the `do-loadbalancer-name` annotation does NOT rename the existing LB — CCM creates a new one and orphans the old. Don't change the name annotation casually.
- **External-dns + LB IP coupling**. external-dns reads the Service's `EXTERNAL-IP` to build A records. If CCM ever fails to update the IP (e.g. DO API outage), DNS goes stale. external-dns's 10m reconcile interval bounds the staleness window.

## Hand-off contract to Phase 4 (bare-metal)

CCM is DO-specific. On bare metal it's removed entirely and replaced with one of:
- **MetalLB** (already vendored under `apps/metallb/`): assigns IPs from a pool, handles ARP/BGP.
- **kube-vip**: similar role, less BGP-heavy.

The ingress-nginx values changes from this PR (DO-specific annotations) would also be reverted/replaced with MetalLB-specific configuration. Phase-4 OpenSpec proposal will own that swap. The decision to expose public HTTP/HTTPS at the cluster level (recorded in the access-model runbook) carries forward as a policy, independent of the LB implementation.
