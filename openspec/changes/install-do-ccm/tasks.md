# Tasks — install-do-ccm

**Tracking issue:** [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25)

Two-group split mirroring `enable-longhorn`. Group 1 is repo work that lands as a PR; Group 2 is cluster validation at the next bring-up.

## Group 1 — repo work (no cluster needed)

### Vendor the CCM manifest

- [ ] 1. Pick the CCM version. Check <https://github.com/digitalocean/digitalocean-cloud-controller-manager/releases> for the latest stable matching RKE2's Kubernetes version (currently v1.35). As of 2026-05-16 that's `v0.1.67`. Record the chosen version in the PR description.
- [ ] 2. Create `apps/digitalocean-cloud-controller-manager/`. Curl the upstream release manifest verbatim into `ccm.yaml`:
  ```bash
  mkdir -p apps/digitalocean-cloud-controller-manager
  curl -sLo apps/digitalocean-cloud-controller-manager/ccm.yaml \
    https://raw.githubusercontent.com/digitalocean/digitalocean-cloud-controller-manager/master/releases/digitalocean-cloud-controller-manager/v0.1.67.yml
  ```
  Add a one-line provenance comment at the top of the file noting the upstream source + version + retrieval date.
- [ ] 3. Write `apps/digitalocean-cloud-controller-manager/kustomization.yaml` per design.md "Kustomization shape". Includes `ccm.yaml` + `secrets.yaml` as `resources:`, sets `namespace: kube-system` defensively.
- [ ] 4. Create the SOPS-encrypted Secret:
  - Write the plaintext to `apps/digitalocean-cloud-controller-manager/secrets.yaml.decrypted` (gitignored).
  - Reuse the existing DO PAT from `terraform/environments/do-test/secrets.enc.tfvars` (decrypt with `sops -d`, copy the `do_token` value into the `access-token` key).
  - Secret manifest per design.md "Secret shape": name=`digitalocean`, namespace=`kube-system`, key=`access-token`.
  - Run `./encrypt_secrets.sh` to produce `secrets.yaml` encrypted with our age recipients.
  - Confirm `git status` does not show the `.decrypted` file.
- [ ] 5. `kustomize build apps/digitalocean-cloud-controller-manager/` renders cleanly (Deployment + ServiceAccount + ClusterRole + ClusterRoleBinding + Secret all in `kube-system`).

### Ansible kubelet flag

- [ ] 6. Add `rke2_kubelet_args` default to `ansible/roles/rke2_common/defaults/main.yml` per design.md "Ansible role / kubelet flag". Default value: `["cloud-provider=external"]`.
- [ ] 7. Append the `{% if rke2_kubelet_args %}` block to `ansible/roles/rke2_server/templates/config.yaml.j2`. Same block to `ansible/roles/rke2_agent/templates/config.yaml.j2`.
- [ ] 8. `ansible-lint roles/rke2_common roles/rke2_server roles/rke2_agent` clean. `yamllint roles/rke2_common/defaults/main.yml` clean.

### Wire up ingress-nginx for CCM

- [ ] 9. Edit `apps/ingress-nginx/values.yaml`:
  - Remove `service.beta.kubernetes.io/aws-load-balancer-type: nlb`.
  - Add the four DO annotations from design.md (`do-loadbalancer-name`, `do-loadbalancer-size-unit`, `do-loadbalancer-protocol`, `do-loadbalancer-disable-lets-encrypt-dns-records`).
  - Keep `externalTrafficPolicy: Local` and `ipFamilies: [IPv4]` as-is.
- [ ] 10. Edit `apps/ingress-nginx/release.yaml`:
  - Drop the `install.disableWait: true` / `upgrade.disableWait: true` blocks.
  - Drop the "Revisit if we ever install DO's cloud controller (Phase 4-ish?)" comment.
- [ ] 11. `kustomize build apps/ingress-nginx/` renders cleanly.

### deploy.sh

- [ ] 12. Edit the `rke2)` branch (`deploy.sh`): set `app_list="digitalocean-cloud-controller-manager.yaml longhorn.yaml"` (alphabetical/grouped order — see design.md). If `enable-longhorn` hasn't landed yet, use `app_list="digitalocean-cloud-controller-manager.yaml"` and rebase when Longhorn lands.

### Docs

- [ ] 13. Write `docs/runbooks/install-do-ccm.md`:
  - Prereqs: cluster up, Flux bootstrapped, kubelet flag applied via `make play` (or being applied as part of this bring-up).
  - Enable: `./deploy.sh` (picks up the new Kustomization).
  - Verify: success-criteria checklist from proposal.md (Kustomization Ready, CCM pods Ready, taint removed from nodes, `providerID` populated, zone labels populated, ingress-nginx `EXTERNAL-IP` populated, DO UI shows new LB, canary Ingress end-to-end).
  - Expected Pending window: 30-60s on fresh bring-up between kubelet restart and CCM untainting.
  - Triage if cluster gets wedged in Pending: `flux get kustomization -A`, `kubectl -n kube-system logs deploy/digitalocean-cloud-controller-manager`, confirm Secret decryption (`sops -d apps/digitalocean-cloud-controller-manager/secrets.yaml`), confirm DO API reachability from a CP.
  - Rollback: drop the Kustomization entry from deploy.sh app_list + `flux reconcile`, then set `rke2_kubelet_args: []` in inventory + `make play` to untaint nodes. ~1-2 minutes total. Cluster returns to pre-CCM state.
  - Cost: ~$12/mo for the LB while up; LB destroyed by CCM when the cluster's ingress-nginx Service is deleted (which happens on `make destroy`).
- [ ] 14. Write `docs/diagrams/public-traffic-path.md` per design.md outline. Cross-link from the new runbook and from `do-network.md` (sibling diagram showing the existing internal LB path).
- [ ] 15. Edit `docs/runbooks/do-bring-up.md` "Access model" section: append the HTTP/443 bullet per design.md.
- [ ] 16. Edit `CLAUDE.md` access-model section (if it lists ports): add the HTTP/443 entry with cross-link to the runbook. Skip if the CLAUDE.md text just references do-bring-up.md without a port list.

### Close-out Group 1

- [ ] 17. Verify secrets safe-staging before push: no plaintext DO PAT, no `.decrypted` files staged, no kubeconfig.
- [ ] 18. Open PR with commits grouped by concern:
  - `feat(do-ccm): vendor digitalocean-cloud-controller-manager v0.1.67 as Flux Kustomization`
  - `feat(ansible): add rke2_kubelet_args default with cloud-provider=external`
  - `feat(ingress-nginx): swap AWS NLB annotations for DO LB annotations`
  - `docs: install-do-ccm runbook + public-traffic-path diagram + access-model update`
- [ ] 19. PR description includes: pinned CCM version, the deliberate decision to expose public HTTP/443 with reasoning + mitigations, the bring-up Pending window expectation.
- [ ] 20. Merge to `main`. Issue stays open until Group 2 validation completes.

## Group 2 — at-bring-up validation (cluster running)

> **Pre-flight:** Cluster is up per `do-bring-up.md` + `rke2-install.md` + `fluxcd-bootstrap.md`. The deploy.sh fixes from #24 are in place (already landed in `fc76c27`) so second-cluster bring-up succeeds without manual intervention.

- [ ] 21. `cd terraform/environments/do-test && make apply`. Confirm 6 droplets + 3 volumes + 1 internal LB + persisted VPC. No drift.
- [ ] 22. `cd ansible && make inventory && make play`. Confirm `failed=0 unreachable=0` and that `config.yaml` on every node now has the `kubelet-arg: ["cloud-provider=external"]` line.
- [ ] 23. Immediately after `make play` (before `./deploy.sh`): `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints}{"\n"}{end}'` shows every node tainted with `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`. Expected state — nothing else can schedule until CCM lands.
- [ ] 24. `cd .. && ./deploy.sh`. CCM Kustomization should reconcile first (CCM tolerates the taint, others don't).
- [ ] 25. `kubectl -n kube-system get pods -l app=digitalocean-cloud-controller-manager` shows Deployment Ready within 1 min.
- [ ] 26. Within 30s of CCM Ready: `kubectl get nodes -o wide` shows the `uninitialized` taint is gone and `spec.providerID` is `digitalocean://<id>` on every node.
- [ ] 27. `kubectl get nodes --show-labels | grep topology` shows `topology.kubernetes.io/region=nyc3` and `topology.kubernetes.io/zone=...` on every node.
- [ ] 28. `kubectl -n ingress-nginx get svc ingress-nginx-controller` reports a real `EXTERNAL-IP` (public IPv4) within 2 min of CCM reconciling.
- [ ] 29. DO control panel → Networking → Load Balancers: confirm a new LB named `do-nyc3-rke2-demo-ingress` exists, `lb-small`, attached to all worker droplets (or whatever hosts ingress-nginx replicas), forwarding rules tcp/80 → tcp/80 and tcp/443 → tcp/443, health check on tcp/80 to `/healthz`.
- [ ] 30. Apply the canary Ingress from `docs/runbooks/dns-migration-to-do.md` step 6 (or re-cite from this runbook). Watch:
  - `kubectl -n external-dns logs deploy/external-dns -f` → log line creating the A record for `canary.escapekey.org` pointing at the LB EXTERNAL-IP.
  - `dig +short A canary.escapekey.org @ns1.digitalocean.com` → returns the LB IP within 30s.
  - `kubectl get certificate canary-escapekey-tls -n default` → READY=True within ~2 min (cert-manager DNS-01 path).
  - `curl -v https://canary.escapekey.org` → returns the canary payload; `openssl s_client` confirms cert chain is Let's Encrypt (issuer CN=R12 or current).
- [ ] 31. Tear down the canary (`kubectl delete ingress,svc,deploy dns-cert-canary -n default`). Confirm external-dns removes the A record on next reconcile.
- [ ] 32. `make -C ansible play` again -- expect `changed=0`. Confirms idempotency.
- [ ] 33. `make -C terraform destroy`. Confirm the DO LB is destroyed by CCM as part of the ingress-nginx Service teardown (DO UI should show no LB after destroy completes). VPC remains (per #26 fix).
- [ ] 34. Close tracking issue. Comment links to the PR and verification command outputs.

## Archive

- [ ] 35. `git mv openspec/changes/install-do-ccm openspec/changes/archive/<YYYY-MM-DD>-install-do-ccm`. Commit `docs(openspec): archive install-do-ccm`.
