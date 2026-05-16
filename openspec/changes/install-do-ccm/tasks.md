# Tasks — install-do-ccm

**Tracking issue:** [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25)

Two-group split mirroring `enable-longhorn`. Group 1 is repo work that lands as a PR; Group 2 is cluster validation at the next bring-up.

## Group 1 — repo work (no cluster needed)

### Scaffold the CCM app

- [ ] 1. Pin the CCM Helm chart version. Check <https://github.com/digitalocean/digitalocean-cloud-controller-manager/releases> and <https://charts.digitalocean.com/index.yaml> for the latest stable matching RKE2's Kubernetes version (currently v1.35). Record the chosen version in the PR description.
- [ ] 2. Run `./deploy_new_app.sh digitalocean-cloud-controller-manager digitalocean https://charts.digitalocean.com digitalocean-cloud-controller-manager <version>` to scaffold the directory.
- [ ] 3. Edit `apps/digitalocean-cloud-controller-manager/values.yaml` per design.md "CCM chart + values" (clusterName, replicaCount, nodeSelector, tolerations, resources).
- [ ] 4. Create the SOPS-encrypted Secret:
  - Write the plaintext to `apps/digitalocean-cloud-controller-manager/secrets.yaml.decrypted` (gitignored).
  - Reuse the existing DO PAT from `terraform/environments/do-test/secrets.enc.tfvars` (decrypt with `sops -d`, copy the `do_token` value).
  - Run `./encrypt_secrets.sh` to produce `secrets.yaml` encrypted with our age recipients.
  - Confirm `git status` does not show the `.decrypted` file (gitignore is doing its job).
- [ ] 5. `kustomize build apps/digitalocean-cloud-controller-manager/` renders cleanly.

### Wire up ingress-nginx for CCM

- [ ] 6. Edit `apps/ingress-nginx/values.yaml`:
  - Remove `service.beta.kubernetes.io/aws-load-balancer-type: nlb`.
  - Add the four DO annotations from design.md (`do-loadbalancer-name`, `do-loadbalancer-size-unit`, `do-loadbalancer-protocol`, `do-loadbalancer-disable-lets-encrypt-dns-records`).
  - Keep `externalTrafficPolicy: Local` and `ipFamilies: [IPv4]` as-is.
- [ ] 7. Edit `apps/ingress-nginx/release.yaml`:
  - Drop the `install.disableWait: true` / `upgrade.disableWait: true` blocks.
  - Drop the "Revisit if we ever install DO's cloud controller (Phase 4-ish?) OR if we decide to flip the Service to ClusterIP" comment.
- [ ] 8. `kustomize build apps/ingress-nginx/` renders cleanly.

### deploy.sh

- [ ] 9. Edit the `rke2)` branch (`deploy.sh`): set `app_list="digitalocean-cloud-controller-manager.yaml longhorn.yaml"` (alphabetical/grouped order — see design.md). If `enable-longhorn` hasn't landed yet, use `app_list="digitalocean-cloud-controller-manager.yaml"` and rebase when Longhorn lands.

### Docs

- [ ] 10. Write `docs/runbooks/install-do-ccm.md`:
  - Prereqs: cluster up + Flux bootstrapped (`fluxcd-bootstrap.md` completed).
  - Enable: `./deploy.sh` (idempotent; picks up the new app_list).
  - Verify: success-criteria checklist from proposal.md (HelmRelease Ready, CCM pods Ready, `providerID` on nodes, ingress-nginx `EXTERNAL-IP` populated, DO UI shows new LB, canary Ingress end-to-end with real cert + real DNS A record).
  - Rollback: remove `digitalocean-cloud-controller-manager.yaml` from deploy.sh app_list, `kubectl delete helmrelease -n digitalocean-cloud-controller-manager <name>`. Ingress-nginx Service goes back to `<pending>` EXTERNAL-IP. The DO LB is deleted by CCM during teardown.
  - Cost: ~$12/mo while the cluster is up; LB destroyed with `make destroy`.
- [ ] 11. Write `docs/diagrams/public-traffic-path.md` per design.md outline. Cross-link from the new runbook and from `do-network.md` (sibling diagram showing the existing internal LB path).
- [ ] 12. Edit `docs/runbooks/do-bring-up.md` "Access model" section: append the HTTP/443 bullet per design.md.
- [ ] 13. Edit `CLAUDE.md` access-model section (if it lists ports): add the HTTP/443 entry with cross-link to the runbook. (Skip if the CLAUDE.md text just references do-bring-up.md without a port list.)

### Close-out Group 1

- [ ] 14. Verify secrets safe-staging before push: no plaintext DO PAT, no `.decrypted` files staged, no kubeconfig.
- [ ] 15. Open PR with commits grouped by concern:
  - `feat(do-ccm): scaffold digitalocean-cloud-controller-manager app`
  - `feat(ingress-nginx): swap AWS NLB annotations for DO LB annotations`
  - `docs: install-do-ccm runbook + public-traffic-path diagram + access-model update`
- [ ] 16. PR description includes: pinned chart version, the deliberate decision to expose public HTTP/443 with reasoning + mitigations, screenshot/dig output for any DNS record planned.
- [ ] 17. Merge to `main`. Issue stays open until Group 2 validation completes.

## Group 2 — at-bring-up validation (cluster running)

> **Pre-flight:** Cluster is up per `do-bring-up.md` + `rke2-install.md` + `fluxcd-bootstrap.md`. The deploy.sh fixes from #24 are in place so a second-cluster bring-up succeeds without manual intervention.

- [ ] 18. `cd terraform/environments/do-test && make apply`. Confirm 6 droplets + 3 volumes + 1 internal LB + persisted VPC. No drift.
- [ ] 19. `cd ansible && make inventory && make play`. Confirm `failed=0 unreachable=0`.
- [ ] 20. `cd .. && ./deploy.sh`. Confirm both `digitalocean-cloud-controller-manager.yaml` and `longhorn.yaml` (if `enable-longhorn` has landed) reconcile.
- [ ] 21. `kubectl -n digitalocean-cloud-controller-manager get pods` shows CCM Deployment Ready within 2 min.
- [ ] 22. `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'` shows every node with `digitalocean://<id>` provider ID.
- [ ] 23. `kubectl -n ingress-nginx get svc ingress-nginx-controller` reports a real `EXTERNAL-IP` (public IPv4) within 2 min of CCM reconciling.
- [ ] 24. DO control panel → Networking → Load Balancers: confirm a new LB named `do-nyc3-rke2-demo-ingress` exists, `lb-small`, attached to all worker droplets (or whatever hosts ingress-nginx replicas), forwarding rules tcp/80 → tcp/80 and tcp/443 → tcp/443, health check on tcp/80 to `/healthz` (or whatever ingress-nginx default).
- [ ] 25. Apply the canary Ingress from `docs/runbooks/dns-migration-to-do.md` step 6 (or re-cite from this runbook). Watch:
  - `kubectl -n external-dns logs deploy/external-dns -f` → log line creating the A record for `canary.escapekey.org` pointing at the LB EXTERNAL-IP.
  - `dig +short A canary.escapekey.org @ns1.digitalocean.com` → returns the LB IP within 30s.
  - `kubectl get certificate canary-escapekey-tls -n default` → READY=True within ~2 min (cert-manager DNS-01 path).
  - `curl -v https://canary.escapekey.org` → returns the canary payload; `openssl s_client` confirms cert chain is Let's Encrypt (issuer CN=R12 or current).
- [ ] 26. Tear down the canary (`kubectl delete ingress,svc,deploy dns-cert-canary -n default`). Confirm external-dns removes the A record on next reconcile.
- [ ] 27. `make -C terraform destroy`. Confirm the DO LB is destroyed by CCM as part of the ingress-nginx Service teardown (DO UI should show no LB after destroy completes).
- [ ] 28. Close tracking issue. Comment links to the PR and verification command outputs.

## Archive

- [ ] 29. `git mv openspec/changes/install-do-ccm openspec/changes/archive/<YYYY-MM-DD>-install-do-ccm`. Commit `docs(openspec): archive install-do-ccm`.
