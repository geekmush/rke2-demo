# Proposal — install-do-ccm

**Tracking issue:** [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25)
**Phase:** 3d — DigitalOcean Cloud Controller Manager.
**Status:** draft 2026-05-16 (revised after pre-flight findings — see below).

## Why

> **CCM** = **Cloud Controller Manager** — the standard Kubernetes component that bridges cluster objects to a cloud provider's API. Every managed Kubernetes offering (EKS, GKE, AKS, DOKS) ships its own CCM; RKE2 on raw DigitalOcean droplets does not, which is why we have to install one. CCM watches the cluster and translates Kubernetes objects into provider-side actions — most visibly, turning a `Service` of `type: LoadBalancer` into an actual DigitalOcean Load Balancer and writing its public IP back onto the Service. It also populates `Node` fields like `spec.providerID` and region/zone labels from the cloud provider's view of each VM.

RKE2 on DigitalOcean ships without a cloud-provider integration by default. The `apps/ingress-nginx/release.yaml` comment documents the visible symptom: the ingress-nginx `Service` of `type: LoadBalancer` stays `EXTERNAL-IP <pending>` indefinitely, because nothing translates `LoadBalancer` Services into DO Load Balancers. The 2026-05-16 unattended end-to-end test surfaced this concretely — DNS-01 cert issuance worked anyway (cert-manager only needs DO API access), but external-dns never created the canary A record (no LB IP to advertise), and any actual app traffic would have nowhere to land.

This change installs the [`digitalocean-cloud-controller-manager`](https://github.com/digitalocean/digitalocean-cloud-controller-manager) — DigitalOcean's implementation of that CCM interface — so:
- `LoadBalancer`-type Services trigger DO LB provisioning.
- `Node` objects get DO-source-of-truth fields (`spec.providerID`, `status.addresses`, region/zone labels).
- The cluster behaves like a "real" managed-cloud cluster from the kubelet's perspective.

End-state outcome: the canary Ingress from the unattended-test runbook becomes fully exercisable — public HTTPS traffic to `canary.escapekey.org` lands at ingress-nginx through a DO public LB, with a real Let's Encrypt cert and an external-dns-managed A record.

## Pre-flight findings (corrected from initial draft)

Two assumptions in the original draft turned out to be wrong on closer inspection. Surfacing them up front because they reshape the install path:

1. **DO does not publish a Helm chart for the CCM.** The original draft cited `https://charts.digitalocean.com/`, but that host doesn't resolve and no community Helm chart exists on ArtifactHub. The CCM upstream README directs you to vendor a single self-contained YAML manifest from [`releases/digitalocean-cloud-controller-manager/v<x.y.z>.yml`](https://github.com/digitalocean/digitalocean-cloud-controller-manager/tree/master/releases/digitalocean-cloud-controller-manager) in the project's GitHub repo. The manifest carries the Deployment + ServiceAccount + ClusterRole + ClusterRoleBinding and is pinned to a `kube-system` namespace by default. Install mechanism therefore = **vendored YAML reconciled by a Flux `Kustomization`**, not a `HelmRelease`.
2. **CCM requires `--cloud-provider=external` on every kubelet** per the upstream getting-started docs. RKE2 doesn't set this by default. Without it, kubelet doesn't mark nodes with the `node.cloudprovider.kubernetes.io/uninitialized` taint that CCM uses as its "please initialize me" signal — so node-side features (`spec.providerID` injection, region/zone labels) don't happen, and `LoadBalancer` Service provisioning is best-effort / undefined. **This is an Ansible role change**, not a Flux app change, and it interacts with bring-up sequencing: every kubelet starts up tainted, so general workloads cannot schedule until CCM is up to untaint. CCM itself tolerates the taint so it can land.

These two findings drive the design — see "What this change ships" + the Sequencing note below.

## Security: this is a deliberate new public surface

The current cluster has **no public ingress path**. CLAUDE.md's access model only opens TCP/22 (SSH, key-only) to the world; everything else is VPC-internal. Installing CCM and letting the ingress-nginx Service become a real LB opens TCP/80 + TCP/443 on a new public IP — every HTTP request on those ports hits ingress-nginx, which routes by `Ingress` resources.

CLAUDE.md is explicit: **"Anything that loosens this needs an explicit user decision recorded in a runbook."** This change is that decision. Mitigations baked into the design:

- Ingress controller is single-class (`nginx`) and `ingressClassResource.default: true` is already set, so accidentally exposing an app requires deliberate `kubernetes.io/ingress.class: nginx` annotation + a matching `Ingress` rule, not a one-off `Service` of type LoadBalancer.
- external-dns is scoped to `escapekey.org` only (per PR #22's `domainFilters`), so typo'd hostnames in other domains do not get DNS even if someone fat-fingers an Ingress.
- DO LB exposes only the two ports defined by the ingress-nginx Service (80, 443); other TCP services would need explicit annotations to be tunneled.
- LB-level firewall (DO supports source-IP allowlists on LBs) is **out of scope** for this change — see below.

The decision recorded in this change: **public HTTP/HTTPS ingress is acceptable for the do-nyc3-rke2-demo cluster during the test phase**, because (a) the cluster is named-test-only, (b) no production workloads run on it, (c) the only Ingress-exposed workloads will be deliberate test/demo apps. For the future bare-metal production cluster, revisit and add an LB-level firewall narrowing source IPs to whatever fronting CDN/VPN is in use.

## What this change ships

- **New Flux-managed app under `apps/digitalocean-cloud-controller-manager/`** — hand-authored (the `./deploy_new_app.sh` scaffolder assumes HelmRepository / OCIRepository sources and doesn't fit this YAML-vendor pattern):
  - `ccm.yaml`: vendored from upstream `releases/digitalocean-cloud-controller-manager/v0.1.67.yml` (or whatever's latest at PR time). Pinned to a specific version; upgrade is a deliberate copy of a new version.
  - `kustomization.yaml`: Kustomize entry listing `ccm.yaml` + `secrets.yaml`. No HelmRelease.
  - `secrets.yaml`: SOPS-encrypted `Secret/digitalocean.access-token` in `kube-system` namespace (matches what the upstream manifest expects). **Reuses the existing full-access DO PAT** that Tofu, external-dns, and cert-manager already share. Production-phase TODO in design.md about splitting into a least-privilege CCM-only token.
  - No `namespace.yaml` — the upstream manifest pins `kube-system`, which already exists; creating it would be a no-op.
- **New Ansible role `cloud_provider_external`** (or a one-line addition to `rke2_common` — design.md picks one):
  - Adds `kubelet-arg: ["cloud-provider=external"]` to `/etc/rancher/rke2/config.yaml` on every node, both server and agent templates.
  - Triggers a controlled `systemctl restart rke2-server` / `rke2-agent` on apply via existing handlers.
  - Idempotent across re-runs.
- **`apps/ingress-nginx/values.yaml` updates**: replace the vestigial `service.beta.kubernetes.io/aws-load-balancer-type: nlb` annotation (inherited from the upstream template's AWS-default posture) with DO-specific annotations:
  - `service.beta.kubernetes.io/do-loadbalancer-name`: predictable name in DO UI (e.g. `do-nyc3-rke2-demo-ingress`)
  - `service.beta.kubernetes.io/do-loadbalancer-size-unit`: `1` (smallest, ~$12/mo)
  - `service.beta.kubernetes.io/do-loadbalancer-protocol`: `tcp` (passthrough, ingress-nginx terminates TLS)
  - `service.beta.kubernetes.io/do-loadbalancer-disable-lets-encrypt-dns-records`: `true` (we manage DNS + certs ourselves via external-dns + cert-manager; DO's built-in LE integration would race ours)
- **`apps/ingress-nginx/release.yaml`**: remove the "Revisit if we ever install DO's cloud controller" comment and the `install.disableWait: true` / `upgrade.disableWait: true` blocks, now that LoadBalancer provisioning actually works.
- **`deploy.sh` rke2 branch**: add `digitalocean-cloud-controller-manager.yaml` to the `app_list` alongside whatever the current state has. Coordinates with `enable-longhorn`'s app_list edit; design.md covers the ordering.
- **Operator runbook** `docs/runbooks/install-do-ccm.md`: enable, verify (CCM Deployment Ready, nodes untainted, Service gets EXTERNAL-IP, DO UI shows new LB, canary Ingress reachable end-to-end), rollback (delete the Flux Kustomization for ccm, revert the kubelet flag, re-run Ansible — nodes start without the taint, ingress-nginx Service back to pending).
- **Access-model update** in `docs/runbooks/do-bring-up.md` (Access model section): add HTTP/80 + HTTPS/443 on the new public LB as a deliberate exception, with a one-line "see install-do-ccm runbook" cross-link.
- **Mermaid diagram** `docs/diagrams/public-traffic-path.md`: request flow from internet → DO LB → ingress-nginx → Service → pod, alongside the existing internal LB diagram for the kube API.

## Out of scope (explicit non-goals)

- **LB-level firewall** (source IP allowlist on the DO LB). Test phase is intentionally open. Track as a follow-up when first real workload lands.
- **Least-privilege DO PAT for CCM.** Test phase reuses the shared full-access token. Splitting into a CCM-only PAT with `read+write` on `LB, Firewall, VPC` only is a production-phase concern.
- **Internal LBs for app-to-app traffic.** Apps that should not be public will use `ClusterIP` / Headless services, not `LoadBalancer` with the `internal` annotation. If the need arises later, revisit.
- **WAF / DDoS protection** (DO LB is just L4; an L7 WAF would be a Cloudflare-in-front layer). Out of scope.
- **HTTP-01 cert path.** Now that public HTTP/80 reaches ingress-nginx, cert-manager *could* use HTTP-01 as a fallback. We keep DNS-01 as primary (works regardless of ingress reachability, faster for wildcards, no rate-limit on validations) — but the HTTP-01 solver block in `clusterissuer.yaml` already exists as a fallback, so this just becomes a passively-working option. No code change needed.

## Decisions to lock in (review-driven)

1. **Vendor upstream YAML; do not write a Helm wrapper.** The CCM manifest is small, self-contained, and only changes when DO cuts a release (every few months). A Helm wrapper would be a maintenance overhead with no upside. Pinning is a literal copy of `releases/digitalocean-cloud-controller-manager/v<version>.yml`; upgrade = re-copy.
2. **Pin to `v0.1.67`** at PR time (latest as of 2026-05-16, verified against the upstream GitHub releases). RKE2 v1.35 compatibility per the CCM getting-started's "Use CCM versions >= v0.1.8 if you're running Kubernetes version >= v1.11" — we're well within range.
3. **Set `--cloud-provider=external` on every kubelet** via the existing RKE2 `config.yaml` (`kubelet-arg: ["cloud-provider=external"]`). This is the CCM-supported pattern; running without it works partially but is unsupported and degrades node-side features (no providerID injection, no zone labels).
4. **Reuse the existing `digitalocean-dns` PAT, do not split.** Same full-access scope used by Tofu/external-dns/cert-manager. Simpler secret inventory, matches the current pattern. Production-phase TODO documented in design.md.
5. **`tcp` protocol on the DO LB, not `http`/`https`.** Passthrough so ingress-nginx terminates TLS with cert-manager-issued certs. The `http`/`https` LB modes would terminate at the LB using DO's certs — incompatible with the cert-manager flow already in place.
6. **`do-loadbalancer-disable-lets-encrypt-dns-records: true`** so DO doesn't create its own LE-integration DNS records that race external-dns. Cert + DNS are both ours.
7. **`size-unit: 1`** (smallest LB). ~$12/mo. Plenty for test. Scales up via the annotation; no module change needed.
8. **`externalTrafficPolicy: Local`** (already set in ingress-nginx values.yaml). With CCM, this preserves client source IPs by routing only to nodes hosting an ingress-nginx replica. With 2 replicas across 3 workers, that's healthy.
9. **CCM lands as a separate change, not bundled with Longhorn.** Both can be applied in either order during a single cluster bring-up; their concerns are orthogonal (storage vs. north-south network). enable-longhorn doesn't depend on CCM (PVCs work without LBs), CCM doesn't depend on Longhorn.

## Success criteria

- `flux get kustomization -n flux-system digitalocean-cloud-controller-manager` reports `READY=True` within 5 min of `./deploy.sh` first reconcile.
- `kubectl -n kube-system get deploy digitalocean-cloud-controller-manager` reports `READY 1/1` within 1 min after the Kustomization applies.
- `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'` shows every node with a non-empty `spec.providerID` of form `digitalocean://<droplet-id>`.
- `kubectl describe node <any-worker>` shows the `node.cloudprovider.kubernetes.io/uninitialized` taint is **not present** — CCM removed it after initializing. (Briefly present right after bring-up.)
- `kubectl get nodes --show-labels` shows `topology.kubernetes.io/region=nyc3` and `topology.kubernetes.io/zone=...` on every node, populated by CCM.
- `kubectl -n ingress-nginx get svc ingress-nginx-controller` reports a real `EXTERNAL-IP` (DO LB public IP) within 2 min of CCM reconciling.
- DO control panel → Networking → Load Balancers shows a new LB named `do-nyc3-rke2-demo-ingress` (or whatever the annotation pins), `lb-small` size, attached to all 3 workers (or whatever ingress-nginx replicas exist), health-check on `/healthz`.
- Apply canary Ingress per `docs/runbooks/install-do-ccm.md` (or the existing one from `dns-migration-to-do.md`): `curl https://canary.escapekey.org` returns the expected payload, cert chain is Let's Encrypt, external-dns has created the A record at DO pointing at the LB IP, A record matches the LB IP.
- `kubectl -n longhorn-system get nodes.longhorn.io -o yaml | grep zone` (if Longhorn is installed) shows zone labels propagated to Longhorn from CCM-sourced node labels.
- `make -C ansible play` is idempotent on the second run (`changed=0`) after the role addition has already been applied once.

## Sequencing note

Cluster currently destroyed. Two-group split mirroring `enable-longhorn`:

- **Pre-bring-up (no cluster needed):** vendor the CCM YAML, encrypt the Secret with our age recipients, add the Ansible kubelet-flag role/edit, swap ingress-nginx annotations, edit deploy.sh, write runbook + diagram — all in one PR before any cluster work.
- **At-bring-up (cluster on):**
  1. `make apply` (Tofu, unchanged).
  2. `make play` (now includes the kubelet flag → every node comes up with `node.cloudprovider.kubernetes.io/uninitialized` taint).
  3. `./deploy.sh` — Flux brings up CCM first (it tolerates the taint), CCM initializes every node and removes the taint, then the rest of the apps schedule normally.
  4. Validate per success criteria.

**Bring-up failure mode to watch for**: if CCM Kustomization fails to apply (e.g. SOPS decryption error on its Secret), every other workload sits Pending forever because no node can host non-tolerating pods. The runbook covers triage: confirm CCM logs, confirm Secret decryption, confirm DO API reachability.

Cluster work for this change can ride alongside the next `enable-longhorn` Group 2 bring-up, or stand alone.

## Tracking

Tracking issue: [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25). Predecessors: `add-fluxcd-bootstrap` (Flux + base apps), `add-do-block-storage` (substrate). Adjacent: `enable-longhorn` (orthogonal — storage vs network). Successor: Phase 4 bare-metal migration removes this change (bare-metal doesn't need CCM; ingress-nginx Service flips to NodePort or uses MetalLB).
