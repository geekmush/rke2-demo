# DNS migration to DigitalOcean

Operator procedure for moving `escapekey.org` DNS authority from Dreamhost to DigitalOcean so that `external-dns` and `cert-manager` (DNS-01) can manage records and issue real Let's Encrypt certificates against the cluster.

> **Scope.** One-time cutover. Done once for `escapekey.org`. Re-applies if/when additional zones are brought into the DO account in future.

> **Why DO, not Dreamhost.** Dreamhost will not delegate arbitrary subdomains under a hosted zone, which blocks per-cluster delegation patterns (e.g. `do-nyc3-rke2-demo.escapekey.org` carved out of the parent zone). Moving the whole zone to DO removes that limitation and lets `external-dns` own apex + subdomain records uniformly.

## Pre-conditions

- Domain registered at **Squarespace Domains II LLC** (`whois escapekey.org` → `Registrar: Squarespace Domains II LLC`).
- DO account holds the API token used by Tofu, `external-dns`, and `cert-manager` (same PAT, full-access scope; see [`fluxcd-bootstrap.md`](fluxcd-bootstrap.md)).
- **No active services on the zone at time of cutover.** This runbook describes the simple case: empty zone, no record migration. If active services exist (mail, web, etc.), expand step 2 to inventory and recreate every record at DO *before* flipping nameservers.

## Steps

### 1. Capture starting state

From the operator workstation:

```bash
whois escapekey.org | grep -iE "^(registrar|name server)"
dig +short NS escapekey.org @8.8.8.8
dig +short SOA escapekey.org @8.8.8.8
```

Record the current Dreamhost nameservers in case rollback is needed. Expected pre-cutover NS: `ns1/ns2/ns3.dreamhost.com.`

### 2. Create the empty zone in DigitalOcean

DO control panel → **Networking → Domains → Add a Domain** → enter `escapekey.org`. Do **not** associate it with a droplet or load-balancer (that creates an apex `A` record we don't want).

DO auto-creates:

```
escapekey.org.  SOA  ns1.digitalocean.com. hostmaster.escapekey.org. ...
escapekey.org.  NS   ns1.digitalocean.com.
escapekey.org.  NS   ns2.digitalocean.com.
escapekey.org.  NS   ns3.digitalocean.com.
```

**(Recommended) Add a CAA record** locking issuance to Let's Encrypt:

| Field | Value |
|---|---|
| Type | `CAA` |
| Hostname | `@` |
| Tag | `issue` |
| Value | `letsencrypt.org` |
| Flags | `0` |

CAA is defensive — without it, any CA may issue. With it, only Let's Encrypt may issue (and matches what `apps/cert-manager-custom-resources/clusterissuer.yaml` actually uses).

### 3. Verify DO is serving the zone authoritatively (BEFORE the NS flip)

```bash
dig @ns1.digitalocean.com escapekey.org SOA +short
dig @ns1.digitalocean.com escapekey.org NS  +short
dig @ns1.digitalocean.com escapekey.org CAA +short   # if added
```

Expect:
- SOA returning `ns1.digitalocean.com. hostmaster.escapekey.org. ...`
- Three NS records `ns{1,2,3}.digitalocean.com.`
- The CAA record if added.

If anything is missing, fix it at DO before moving on. Flipping NS to a half-built zone causes a public DNS outage.

### 4. Flip nameservers at Squarespace

Squarespace Domains panel → `escapekey.org` → **DNS / Nameservers** → **Use custom nameservers**:

```
ns1.digitalocean.com
ns2.digitalocean.com
ns3.digitalocean.com
```

Save. Squarespace issues an EPP `domain:update` to the `.org` registry. The parent NS records typically refresh within 5-30 minutes.

### 5. Watch propagation

Parent (`.org` gTLD) delegation:

```bash
dig +trace escapekey.org NS 2>/dev/null | awk '/escapekey\.org\.\s+[0-9]+\s+IN\s+NS/' | sort -u
```

Once the gTLD servers return `ns{1,2,3}.digitalocean.com.` instead of Dreamhost, the parent has flipped.

Public resolver caches:

```bash
for r in 8.8.8.8 1.1.1.1 9.9.9.9; do
  printf "%-12s " "$r"
  dig @$r escapekey.org NS +short | tr '\n' ' '
  echo
done
```

These follow the parent within minutes-to-hours as their cached NS records expire (the `.org` parent NS TTL is ~3600s).

### 6. Validate end-to-end (DNS-01 + external-dns)

> **Requires the cluster to be running.** Skip and defer if running this immediately after [`do-bring-up.md`](do-bring-up.md) has been torn down for cost savings.

After propagation completes and the cluster is up (`./deploy.sh` reconciled cleanly per [`fluxcd-bootstrap.md`](fluxcd-bootstrap.md)):

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: dns-cert-canary
  namespace: default
spec:
  selector: { app: dns-cert-canary }
  ports: [{ port: 80, targetPort: 8080 }]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dns-cert-canary
  namespace: default
spec:
  replicas: 1
  selector: { matchLabels: { app: dns-cert-canary } }
  template:
    metadata: { labels: { app: dns-cert-canary } }
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:1.0
        args: ["-text=cert+dns canary OK", "-listen=:8080"]
        ports: [{ containerPort: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dns-cert-canary
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt
    external-dns.alpha.kubernetes.io/hostname: canary.escapekey.org
spec:
  ingressClassName: nginx
  tls:
    - hosts: [canary.escapekey.org]
      secretName: canary-escapekey-tls
  rules:
    - host: canary.escapekey.org
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: dns-cert-canary
                port: { number: 80 }
EOF
```

Watch:

```bash
kubectl get ingress,certificate,certificaterequest,order,challenge -A -w
kubectl -n external-dns logs deploy/external-dns -f
kubectl -n cert-manager logs -l app.kubernetes.io/name=cert-manager -f --tail=20
```

Pass criteria:
- `external-dns` log shows it creating an `A` record for `canary.escapekey.org` at DO.
- `kubectl get certificate` reports `READY=True` for `canary-escapekey-tls` within ~2 min (DNS-01 challenge completes).
- `curl -k https://canary.escapekey.org` returns `cert+dns canary OK` and the cert chain is real Let's Encrypt (not the cluster's selfsigned issuer).

Tear down with `kubectl delete ingress,svc,deploy dns-cert-canary -n default`. `external-dns` will reap the DNS record on next reconcile (`policy: sync` in [`apps/external-dns/values.yaml`](../../apps/external-dns/values.yaml)).

### 7. Update repo-side scoping

After the zone is live in DO, [`apps/external-dns/values.yaml`](../../apps/external-dns/values.yaml) sets `domainFilters: [escapekey.org]` to scope `external-dns` to this one zone. If additional zones are added to the DO account in future, add them here so `external-dns` only manages zones we intend it to.

## Rollback

If anything goes wrong post-cutover, in Squarespace, restore the original nameservers:

```
ns1.dreamhost.com
ns2.dreamhost.com
ns3.dreamhost.com
```

The Dreamhost zone is untouched (we never deleted records there since there were none migrating). Same propagation window applies in reverse.

Optional: delete the zone at DO once rollback propagation is confirmed (Networking → Domains → `escapekey.org` → "Delete Domain"), but leaving it costs nothing.

## See also

- [`fluxcd-bootstrap.md`](fluxcd-bootstrap.md) — references this runbook for the DNS prerequisite.
- [`docs/diagrams/dns-migration.md`](../diagrams/dns-migration.md) — sequence diagram of the cutover.
