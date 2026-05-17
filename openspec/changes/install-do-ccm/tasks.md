# Tasks — install-do-ccm

**Tracking issue:** [#25](https://github.com/geekmush/do-nyc3-rke2-demo/issues/25)

Two-group split. Group 1 = repo work that lands as PRs; Group 2 = cluster validation at the next bring-up.

## What's already done (PR #30 + #31, do not redo)

The first round of work already landed on `main`. These do not need to be repeated:

- `apps/digitalocean-cloud-controller-manager/{ccm.yaml,kustomization.yaml,secrets.yaml}` — vendored upstream v0.1.67 manifest + SOPS-encrypted Secret + Kustomize entry.
- `flux/flux-system/digitalocean-cloud-controller-manager.yaml` — per-app Flux `Kustomization` manifest (added as a follow-up after PR #30 missed it; in main as commit `5f87ee0`).
- `ansible/inventory/group_vars/all/main.yml` — `rke2_kubelet_args: ["cloud-provider=external"]` default. Rendered into both server + agent `config.yaml.j2` via a conditional `{% if rke2_kubelet_args %}` block.
- `apps/ingress-nginx/values.yaml` — DO LB annotations (name, size-unit=1, protocol=tcp, disable-LE-DNS).
- `docs/runbooks/install-do-ccm.md`, `docs/diagrams/public-traffic-path.md`, `CLAUDE.md` access-model bullet.

What PR #31 backed out and v3 needs to put back:

- `apps/ingress-nginx/release.yaml` — `install.disableWait` / `upgrade.disableWait` blocks (PR #31 restored them for "no CCM" baseline; once v3 CCM works, drop them again).
- `flux/flux-system/kustomization.yaml` — `digitalocean-cloud-controller-manager.yaml` entry in `resources:` list (PR #31 removed).
- `deploy.sh` rke2 branch — `app_list="digitalocean-cloud-controller-manager.yaml"` (PR #31 reverted to `""`).

## Group 1 — v3 repo delta (no cluster needed)

### Ansible: add the load-bearing knob

- [ ] 1. Add `cloud-provider-name: external` to both `ansible/roles/rke2_server/templates/config.yaml.j2` and `ansible/roles/rke2_agent/templates/config.yaml.j2`. Both files; both top-level (not inside any conditional). Comment explaining: "Disables RKE2's embedded cloud-controller so DO CCM can take over node initialization. Pairs with kubelet-arg=cloud-provider=external above."
- [ ] 2. `ansible-playbook --syntax-check playbooks/site.yml` clean.
- [ ] 3. (Optional, nice-to-have) Make this configurable via `rke2_cloud_provider_name` in `group_vars/all/main.yml` with default `external`, rendered through a `{% if rke2_cloud_provider_name %}` block — mirrors the `rke2_kubelet_args` pattern. Phase 4 bare-metal can set it to empty.

### Re-enable the wiring PR #31 backed out

- [ ] 4. Edit `apps/ingress-nginx/release.yaml`: drop the `install.disableWait` / `upgrade.disableWait` blocks PR #31 restored. Drop the inline comment too. ingress-nginx Helm install will now wait for the LoadBalancer Service to get an EXTERNAL-IP — which works once CCM is functional.
- [ ] 5. Edit `flux/flux-system/kustomization.yaml`: re-add `- digitalocean-cloud-controller-manager.yaml` to the `resources:` list.
- [ ] 6. Edit `deploy.sh` rke2 branch: set `app_list="digitalocean-cloud-controller-manager.yaml"` (or include `longhorn.yaml` if `enable-longhorn` has landed by then). Drop the temporary "intentionally OFF" comment block; replace with the v2-style "what each entry enables" comment.

### Docs

- [ ] 7. Update `docs/runbooks/install-do-ccm.md`:
  - Add explicit prereq: "**This change requires a fresh cluster**. If migrating from a pre-#30 cluster, run `make -C terraform destroy` first (per #29 the VPC stays; everything else gets torn down)." Cite the providerID-immutability reason in one line.
  - Update the triage section to include the "providerID=rke2:// rejected by CCM" failure mode discovered in test #2, with the recovery step (destroy + rebuild).
- [ ] 8. No diagram update needed (`public-traffic-path.md` is unchanged by v3).
- [ ] 9. No CLAUDE.md change needed (access-model bullet stays — the public surface is the same).

### Close-out Group 1

- [ ] 10. Verify secrets safe-staging: no `.decrypted` files staged; no plaintext PAT.
- [ ] 11. Open PR with commits grouped:
  - `feat(ansible): add cloud-provider-name=external to rke2 server + agent config`
  - `fix: re-enable CCM wiring now that v3 design provisions LBs end-to-end` (combines the three reverts of PR #31)
  - `docs(install-do-ccm): document fresh-cluster requirement + test-#2 failure mode`
- [ ] 12. PR description should reference this v3 proposal explicitly and call out the destroy-first operational requirement.
- [ ] 13. Merge. Issue stays open until Group 2 validation completes.

## Group 2 — at-bring-up validation (cluster running)

> **Pre-flight (NON-NEGOTIABLE):**
> 1. If a cluster from a pre-v3 bring-up is running, **run `make -C terraform destroy` first**. Existing nodes have `providerID=rke2://...` which is immutable; CCM cannot overwrite it. The VPC persists per #29; only droplets/LB/volumes/firewall get torn down.
> 2. Confirm PR #28's deploy.sh fixes are in place (already landed in `fc76c27`). PR #28 reordered the decryption-block + secret apply, and test #2 surfaced a deploy.sh edge case where the recovery yq commit goes to the wrong branch when operator is not on Flux's tracked branch (see follow-up issue) — **stay on `main` while running deploy.sh** until that's fixed.

- [ ] 14. `cd terraform/environments/do-test && make apply`. Confirm 6 droplets + 3 volumes + 1 internal LB + persisted VPC. No drift.
- [ ] 15. `cd ansible && make inventory && make play`. Confirm `failed=0 unreachable=0`. SSH into one node: `grep -A3 cloud-provider /etc/rancher/rke2/config.yaml` shows both `cloud-provider-name: external` and `kubelet-arg: - cloud-provider=external`.
- [ ] 16. Immediately after `make play` (before `./deploy.sh`): `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\t"}{.spec.taints}{"\n"}{end}'` shows:
  - providerID **empty** (RKE2 not setting it because `cloud-provider-name=external`)
  - taint `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` present on every node
  - **This is the v3 acceptance gate** — if providerID is `rke2://...` here, v3's Ansible edit didn't take effect. Stop and debug.
- [ ] 17. `cd .. && ./deploy.sh`. CCM Kustomization should reconcile first.
- [ ] 18. `kubectl -n kube-system get pods -l app=digitalocean-cloud-controller-manager` shows Deployment Ready within 1 min.
- [ ] 19. **Within 30s of CCM Ready:** `kubectl get nodes -o wide` shows the `uninitialized` taint is gone and `spec.providerID` is `digitalocean://<id>` on every node.
- [ ] 20. `kubectl get nodes --show-labels | grep topology` shows `topology.kubernetes.io/region=nyc3` and `topology.kubernetes.io/zone=...` on every node.
- [ ] 21. `kubectl -n ingress-nginx get svc ingress-nginx-controller` reports a real `EXTERNAL-IP` (public IPv4) within 2 min of CCM reconciling.
- [ ] 22. DO control panel → Networking → Load Balancers: confirm `do-nyc3-rke2-demo-ingress`, `lb-small`, tcp/80 + tcp/443 forwarding rules.
- [ ] 23. Apply the canary Ingress from `docs/runbooks/dns-migration-to-do.md` step 6. Watch:
  - external-dns log: A record creation for `canary.escapekey.org` → LB IP.
  - `dig +short A canary.escapekey.org @ns1.digitalocean.com` → LB IP within 30s.
  - `kubectl get certificate canary-escapekey-tls -n default` → READY=True within ~2 min.
  - `curl https://canary.escapekey.org` from outside the VPC returns the payload; cert chain is Let's Encrypt (issuer CN=R12+).
- [ ] 24. Tear down the canary. Confirm external-dns reaps the A record.
- [ ] 25. `make -C ansible play` again — expect `changed=0`. Confirms idempotency.
- [ ] 26. `make -C terraform destroy`. CCM deletes the DO LB as part of ingress-nginx Service teardown (DO UI shows no LB after destroy). VPC retained per #29.
- [ ] 27. Close tracking issue. Comment links to verification command outputs.

## Archive

- [ ] 28. `git mv openspec/changes/install-do-ccm openspec/changes/archive/<YYYY-MM-DD>-install-do-ccm`. Commit `docs(openspec): archive install-do-ccm`.
