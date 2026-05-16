# DNS migration to DigitalOcean — sequence

Cutover flow for moving `escapekey.org` DNS authority from Dreamhost to DigitalOcean. See [`docs/runbooks/dns-migration-to-do.md`](../runbooks/dns-migration-to-do.md) for the operator procedure this diagram describes.

## Sequence

```mermaid
sequenceDiagram
    autonumber
    actor Op as Operator
    participant DO as DigitalOcean<br/>(Networking → Domains)
    participant SQ as Squarespace<br/>(registrar)
    participant ORG as .org gTLD<br/>(parent NS)
    participant Pub as Public resolvers<br/>(8.8.8.8, 1.1.1.1, 9.9.9.9)
    participant Cls as Cluster<br/>(external-dns + cert-manager)

    Note over DO: Zone does not exist yet
    Note over SQ,ORG: NS = ns{1,2,3}.dreamhost.com

    Op->>DO: Add Domain (escapekey.org)
    DO-->>Op: SOA + NS (ns{1,2,3}.digitalocean.com)
    Op->>DO: Add CAA @ issue letsencrypt.org
    Op->>DO: dig @ns1.digitalocean.com SOA / NS / CAA
    DO-->>Op: Authoritative answers OK

    Op->>SQ: Set custom nameservers → DO
    SQ->>ORG: EPP domain:update
    Note over ORG: Parent NS refreshes (~5–30 min)
    ORG-->>Pub: New NS on next cache miss
    Note over Pub: Cached NS expires (TTL ~3600s)

    loop until all resolvers report DO NS
        Op->>Pub: dig escapekey.org NS
        Pub-->>Op: NS records
    end

    Note over Cls: (Phase 3c+ / when cluster is up)
    Op->>Cls: kubectl apply canary Ingress<br/>host: canary.escapekey.org
    Cls->>DO: external-dns: create A canary.escapekey.org → LB IP
    Cls->>DO: cert-manager: create _acme-challenge TXT
    Cls->>Cls: ACME DNS-01 validates → real LE cert issued
    Cls-->>Op: Certificate Ready=True; curl https://canary.escapekey.org OK
```

## Notes

- **Parent (`.org`) TTL** dominates the cutover window. Squarespace pushes the EPP update within minutes, but `.org` itself caches NS records for ~3600s, and downstream public resolvers cache for the same.
- **No record migration** in this cutover because no active services were running on the zone at the time. If services exist, recreate every record at DO between steps 1 and 4 (zone-create and NS-flip), and lower TTLs at the source 24–48 h ahead of cutover.
- **Same DO PAT** powers Tofu, `external-dns`, and `cert-manager`. No new credentials are needed — once the zone exists in the DO account, all three already have authority over it.
