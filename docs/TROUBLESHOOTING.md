# TROUBLESHOOTING — RKE2 + DigitalOcean (with Hivelocity / bare-metal portability notes)

Symptom-indexed reference for the issues that surfaced across the 8-test install-do-ccm validation arc (2026-05-16 → 2026-05-17). Each entry: **what you see**, **root cause**, **fix or workaround**, **which PR/issue codified the fix**, and **portability** to the future Hivelocity-VPS-CPs + bare-metal-workers cluster.

> **How to use this doc.** Operator hits a symptom → scroll to the section name that matches → follow the recipe. Each section ends with cross-refs so you can read the PR for context. The bring-up reference + pre-flight checklist at the top exist so you can avoid most of these symptoms in the first place.

---

## Bring-up sequence (canonical)

```
1. cd terraform && make apply            (Tofu — DO substrate)
2. cd ansible && make inventory && make play   (RKE2 + cloud-provider knobs)
3. ./ansible/scripts/kube-tunnel.sh &    (SSH tunnel to VPC-internal API LB)
4. ./deploy.sh                           (Flux bootstrap + sops-age + apps reconcile)
5. (validate per docs/runbooks/install-do-ccm.md verify section)
6. cd terraform && make destroy          (between sessions; VPC persists per #29)
```

Logs land in `/tmp/`:
- `tofu-apply*.log`, `tofu-destroy*.log`
- `ansible-play*.log`
- `deploy*.log`
- `kube-tunnel*.log`

Where each stage *should* succeed:
- Tofu apply: ~3 min, exits 0, 16 resources created (6 droplets + 3 volumes + 3 attachments + LB + FW + project + SSH key), VPC reused.
- Ansible play: ~4 min, PLAY RECAP shows `failed=0 unreachable=0` for all 6 hosts.
- Tunnel: starts in <5s, `kubectl get --raw=/readyz` returns "ok".
- deploy.sh: ~3-5 min, exit 0, all six Flux Kustomizations Ready=True within ~30s of script end.
- Total wall clock: ~10-15 min for a clean bring-up.

---

## Pre-flight checklist (do this BEFORE every bring-up)

1. **`git branch --show-current` is the Flux-tracked branch** (default `main`). PR #33 makes deploy.sh refuse otherwise — but on bare metal you'd lose this guard if you skip the deploy.sh from the upstream template, so the check is yours to make.
2. **Operator-local credentials present**:
   - `~/.ssh/do_nyc3_rke2_demo_ed25519` (SSH key for ansible — rename for Hivelocity)
   - `~/.config/sops/age/keys.txt` (operator age key for SOPS decryption)
   - `../rke-token.env` containing `GITHUB_TOKEN` for `flux bootstrap github`
3. **`secrets.enc.tfvars` decryptable** by the operator's age key: `sops -d terraform/environments/do-test/secrets.enc.tfvars | head -3` should print the do_token line.
4. **No stale DNS records at the DNS provider** that could collide with this cluster's external-dns work. See "Orphan TXT records persist at the DNS provider" below.
5. **DO LE quota check** (if planning a cert-issuance test): `canary.escapekey.org` cert quota is **5 per identifier per 168 hours**. After 5+ test cycles in a week, use `letsencrypt-staging` (PR #54) instead of `letsencrypt`.

---

## Index

| Symptom | Section |
|---|---|
| Tofu apply / destroy issues | [Tofu](#tofu) |
| Ansible play fails / not-idempotent | [Ansible](#ansible) |
| kube-tunnel.sh won't connect | [Tunnel](#tunnel) |
| `./deploy.sh` exits non-zero or partial | [deploy.sh](#deploysh) |
| `./deploy.sh` script-level commits/pushes go to wrong branch | [Branch mismatch](#deploysh-branch-mismatch) |
| Project1-dev sed clobbers archived docs | [Project1-dev clobber](#do-nyc3-rke2-demo-clobber) |
| sops-age secret "unknown identity type" cascading errors | [sops-age race](#sops-age-race) |
| `flux bootstrap` health-check timeout | [Flux bootstrap timeout](#flux-bootstrap-timeout) |
| Flux controller pods Pending forever | [Flux pods Pending](#flux-pods-pending) |
| Cluster wedged: nothing scheduling, providerID empty | [Cluster wedged](#cluster-wedged) |
| Nodes show `providerID=rke2://...` (immutable wrong value) | [Wrong providerID](#wrong-providerid) |
| ingress-nginx `EXTERNAL-IP <pending>` | [LB never provisions](#lb-never-provisions) |
| LB IP works internally but not from public | [LB public reachability](#lb-public-reachability) |
| LB has wrong type (REGIONAL_NETWORK vs REGIONAL) | [LB type wrong](#lb-type-wrong) |
| Public curl returns TLS handshake EOF | [TLS handshake EOF](#tls-handshake-eof) |
| `dig` returns empty for canary, but cert issued | [Orphan TXT](#orphan-txt) |
| cert-manager returns 429 from Let's Encrypt | [LE rate limited](#le-rate-limited) |
| `tofu destroy` hangs on VPC, exits non-zero | [VPC destroy](#vpc-destroy) |
| `make destroy` succeeds but tee masks the actual exit code | [Pipefail](#pipefail) |
| coredns Pending → Flux source-controller can't resolve github.com | [coredns Pending](#coredns-pending) |
| `kubectl apply -k apps/<X>/` errors on SOPS-wrapped Secret | [kubectl can't decrypt SOPS](#kubectl-cant-decrypt-sops) |
| Longhorn Node CR shows disk path other than `/var/lib/longhorn` | [Longhorn disk isolation broken](#longhorn-disk-isolation-broken) |
| Longhorn shows 6 Node CRs (CPs included) instead of 3 | [Longhorn on CPs](#longhorn-on-cps) |
| PVC stuck Pending on `storageClassName: longhorn` | [PVC Pending — no schedulable replica](#pvc-pending--no-schedulable-replica) |
| `longhorn_disk_prep` Ansible role fails: device missing | [longhorn_disk_prep: device missing](#longhorn_disk_prep-device-missing) |
| `longhorn_disk_prep` refuses to wipe an existing filesystem | [longhorn_disk_prep: non-matching filesystem](#longhorn_disk_prep-non-matching-filesystem) |
| Worker won't boot after Longhorn enabled — fstab failure | [Worker boot blocked by Longhorn mount](#worker-boot-blocked-by-longhorn-mount) |
| `longhorn-crypto-global` StorageClass missing (expected from upstream template) | [Encrypted SC removed](#encrypted-sc-removed) |

---

## Tofu

### Symptom: `Can not delete default VPCs` on destroy

```
Error: DELETE https://api.digitalocean.com/v2/vpcs/<id>: 403: Can not delete default VPCs
```

**Root cause**: DO marks the first VPC created in a region as that region's default and refuses to delete it via API.

**Fix landed**: PR #29. VPC is now at the env level (`terraform/environments/do-test/vpc.tf`) with `lifecycle.prevent_destroy = true`. `make destroy` uses `tofu destroy -target='module.infra'` to skip the env-level VPC. State for the VPC persists across destroy cycles.

**Migration (if upgrading from pre-#29 layout)**: `tofu -chdir=environments/do-test state mv module.infra.digitalocean_vpc.main digitalocean_vpc.this`. Verified in PR #29.

**Portability**: DO-specific. On Hivelocity VPS, there's typically no equivalent "default VPC" concept — bare-metal workers join via L2/L3 networking the operator configures. The lifecycle.prevent_destroy idea is still useful for anything else that's "this resource survives the cluster" (e.g., a hardware VLAN config, a shared storage allocation).

### Symptom: `yes yes |` pipeline exits 141 (SIGPIPE)

```
$ yes yes | make -C terraform apply
... (apply succeeds)
exit code: 141
```

**Root cause**: `yes` keeps producing output indefinitely. When tofu finishes reading from stdin, it closes the pipe, and `yes` gets SIGPIPE on its next write. With `set -o pipefail` enabled, that propagates as the pipeline's exit code.

**Fix**: use a finite-stream alternative:

```bash
printf 'yes\nyes\n' | make -C terraform apply
```

Two lines is enough because tofu typically prompts twice (apply + auto-approve plan). Adjust if more confirmations needed.

**Portability**: applies to any auto-approve wrapping for any tool. Always preferable to `yes yes |` when you know the prompt count.

### Symptom: `tee` masks the actual exit code of a wrapped command

```
$ make -C terraform destroy 2>&1 | tee /tmp/log
# (destroy actually fails at VPC step)
$ echo $?
0   # tee succeeded, so pipeline exit code is 0
```

**Root cause**: bash pipelines normally exit with the last command's status. `tee` always exits 0 when stdin closes cleanly.

**Fix**: `set -o pipefail` in the shell wrapping the pipeline. The pipeline then exits with the **rightmost non-zero** exit code in the chain.

**Portability**: Universal. Apply to ALL test/CI scripts that wrap state-changing operations.

---

## Ansible

### Symptom: `make play` ssh host key error on a fresh cluster

```
Host key verification failed.
```

**Root cause**: known-hosts file doesn't have the new droplet keys.

**Fix already in place**: `ansible.cfg` has `StrictHostKeyChecking=accept-new` + `UserKnownHostsFile=~/.ssh/known_hosts.rke2demo`. First-connect accepts; subsequent reconnects verify against the saved key.

**Portability**: Cluster-rebuild scenarios: if a host re-uses an IP but rotates its key (DO does this on droplet destroy + recreate at the same IP, rare), known_hosts will mismatch and ansible will error. Quick fix: `ssh-keygen -R <ip> -f ~/.ssh/known_hosts.rke2demo`, then re-run. On Hivelocity, host key continuity is more predictable (long-lived VPS/BM).

### Symptom: `kubelet-arg` or `cloud-provider-name` doesn't render into config.yaml

**Root cause**: typo in `ansible/inventory/group_vars/all/main.yml`, or the rke2_server/agent template's Jinja `{% if rke2_kubelet_args %}` guard is hiding the block.

**Fix**: SSH to a node and `grep -A4 -E 'cloud-provider|kubelet-arg' /etc/rancher/rke2/config.yaml`. Should show both `cloud-provider-name: "external"` and `kubelet-arg: - "cloud-provider=external"`. If either is missing, check `ansible/inventory/group_vars/all/main.yml` for `rke2_kubelet_args` and `rke2_cloud_provider_name`. Re-run `make play`.

**Portability**: The knob is RKE2-specific (`/etc/rancher/rke2/config.yaml`). For k0s/kubeadm-on-bare-metal you'd have different config paths. Pattern (Ansible role renders cloud-provider knobs into kubelet/server config before service start) is the same.

---

## Tunnel

### Symptom: `kubectl` from operator hangs / connection refused

**Root cause**: tunnel script not running, or autossh hasn't established the SSH session yet, or kube-apiserver isn't yet listening (cluster still coming up).

**Fix**: `pgrep -af kube-tunnel.sh` — if not running, start `./ansible/scripts/kube-tunnel.sh &`. Wait ~5s, then `kubectl get --raw=/readyz` should return "ok". The script uses autossh to maintain a tunnel; it auto-reconnects on transient failures.

**Portability**: The tunnel script is generic SSH-port-forward → internal LB. For Hivelocity VPS CPs with a real public-or-VPN-reachable LB, you may not need it; for bare-metal workers on a different network, similar tunnel-in-via-management-host pattern applies.

---

## deploy.sh

### deploy.sh fails at `flux bootstrap` step

```
✗ bootstrap failed with 3 health check failure(s): [...timed out waiting for all resources to be ready]
```

**Probable cause**: Flux controller pods are stuck Pending on the `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint set by RKE2 when `cloud-provider-name=external` is in config. **Without** PR #39's controller tolerations, the bootstrap times out waiting for Flux to come up.

**Fix landed**: PR #39 adds tolerations to all six Flux controllers via `flux/flux-system/flux-resources-patch.yaml`. Verify the patch is applied via `kubectl kustomize flux/flux-system/ | grep -A3 tolerations`.

**Portability**: Same toleration is needed on any cluster running an external CCM with kubelet `--cloud-provider=external`. Whether you're on DO, AWS, GCP, or Hivelocity-with-MetalLB — anywhere a cloud-controller-loop manages node initialization, this toleration applies.

### deploy.sh branch mismatch

```
ERROR: deploy.sh is running on git branch '<feature>', but Flux's
flux-system GitRepository tracks branch 'main'. The self-correcting
commits this script makes would land on '<feature>' -- where Flux
can't see them.
```

**Root cause**: PR #33 added this guard. Running deploy.sh from a non-tracked branch silently corrupts cluster state because the script's recovery commits go to the wrong branch.

**Fix**: Merge your feature branch to `main` first, OR `git checkout main` before running. Override with `DEPLOY_ALLOW_BRANCH_MISMATCH=1` only if you've thought through the consequences (e.g., you're going to merge the branch immediately after).

**Portability**: Universal anti-pattern. Whenever a script self-pushes to git, it MUST check the operator's local branch matches what the consuming system tracks.

### Project1-dev clobber

**Symptom**: After running `./deploy.sh`, archived OpenSpec docs that mention `do-nyc3-rke2-demo` (the upstream template's placeholder) got sed-replaced with the actual cluster name, corrupting historical records.

**Root cause**: deploy.sh's sed-replace loop wasn't excluding archived docs.

**Fix landed**: PR #27. The `grep -rIl do-nyc3-rke2-demo` now passes `--exclude-dir=archive --exclude-dir=openspec`. Inline comments document each exclusion.

**Portability**: Generic — applies to any rename template's sed loop. Phase-5 PR candidate for `devopscoop/fluxcd-template`.

### sops-age race ("unknown identity type")

Most common cluster-wedging failure. Symptom across all child Kustomizations:

```
failed to import 'age.agekey' data from sops decryption Secret
'flux-system/sops-age': failed to parse and add to age identities:
unknown identity type
```

**Root cause** (took 4 PRs to fully untangle):

1. `flux bootstrap` regenerates `gotk-sync.yaml` **without** a SOPS decryption block on every run.
2. deploy.sh adds the block back via `yq`, commits, pushes.
3. Without further protection: the kustomize-controller's first reconcile applies `sops-age.secrets.yaml` from git **as ciphertext** (no decryption configured yet at reconcile-start), overwriting the plaintext apply.
4. Subsequent reconciles can't decrypt because the in-cluster sops-age secret IS now ciphertext.

**Four-layer fix (all in main)**:

- **PR #28 (issue #24)**: deploy.sh's bootstrap check is cluster-state-aware (`kubectl get ns flux-system`), not only repo-state. Without this, fresh-cluster-against-bootstrapped-repo bring-ups skip bootstrap and fail at the sops-age apply.
- **PR #40 (issue #37)**: Wrap the decryption-block-push and sops-age-apply in `flux suspend kustomization flux-system` / `flux resume`. Controller can't race during the window.
- **PR #48 (issue #47)**: Also `kubectl apply -f flux/flux-system/gotk-sync.yaml` while suspended. Updates the in-cluster Kustomization spec with the decryption block atomically, not just git.
- **PR #50 (issue #49)**: Reorder so `flux reconcile source git flux-system` happens **before** `flux resume`. Source-controller refreshes its cached artifact while Kustomization stays suspended; first post-resume reconcile uses the fresh tree.

If the cluster wedges anyway (deploy.sh fails to apply a fix mid-flow, or you're on a pre-#50 baseline), manual recovery:

```bash
flux suspend kustomization flux-system
kubectl apply -f flux/flux-system/gotk-sync.yaml    # update in-cluster spec
sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -   # plaintext
flux reconcile source git flux-system               # refresh source
flux resume kustomization flux-system
flux reconcile kustomization flux-system            # speed up
```

All six child Kustomizations should reach Ready=True within ~60s.

**Portability**: SOPS + age + Flux pattern is provider-agnostic. The whole four-layer fix applies anywhere you bootstrap Flux with an existing repo that has SOPS-encrypted secrets. Strong Phase-5 upstream candidate.

### kubectl can't decrypt SOPS

```
$ kubectl apply -k apps/<X>/
Error from server (BadRequest): error when creating "apps/<X>/":
Secret in version "v1" cannot be handled as a Secret: strict decoding error:
unknown field "sops"
```

**Root cause**: `kubectl apply` doesn't decrypt SOPS-encrypted files. Only Flux's kustomize-controller (configured with `.spec.decryption`) decrypts at apply time. Trying to bypass Flux with `kubectl apply -k` hits the encrypted file as a raw manifest and fails.

**Fix**: don't use `kubectl apply -k` on directories containing SOPS-wrapped secrets. For one-off direct application, decrypt first: `sops -d apps/<X>/secrets.yaml | kubectl apply -f -` + apply the non-secret manifests separately.

**Portability**: Universal. Same constraint on bare metal.

---

## Flux

### Flux bootstrap timeout

See [deploy.sh fails at `flux bootstrap` step](#deploysh-fails-at-flux-bootstrap-step) above.

### Flux pods Pending

```
$ kubectl -n flux-system get pods
helm-controller-...             0/1 Pending
kustomize-controller-...        0/1 Pending
...
```

Same root cause as the bootstrap timeout: `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint not tolerated.

**Fix landed**: PR #39 patches. Verify with `kubectl describe pod -n flux-system <pod>` → should show the toleration in spec.

### Cluster wedged

All child Kustomizations show errors, nothing's actually applying. Could be:

1. **sops-age race** (most common) — see above.
2. **CCM not running so taints don't clear** — check `kubectl -n kube-system get deploy digitalocean-cloud-controller-manager`. Without CCM Ready, the `uninitialized` taint persists and only the patched-with-toleration pods schedule.
3. **GitRepository can't fetch** — check `flux get gitrepository -A`. Common: DNS resolution failure inside the cluster (if coredns is Pending → see [coredns Pending](#coredns-pending)).
4. **Deploy key auth failure** — `flux bootstrap` creates a deploy key in GitHub; if revoked or missing, GitRepository fetch fails. Re-run `flux bootstrap` to recreate.

Triage order: `flux get all -A` → identify which controller is unhappy → check that controller's logs.

---

## CCM / providerID

### Wrong providerID (`rke2://<name>`)

```
$ kubectl get nodes -o jsonpath='{range .items[*]}{.spec.providerID}{"\n"}{end}'
rke2://do-nyc3-rke2-demo-cp-01
rke2://...
```

**Root cause**: RKE2 set its own providerID at first node-join because `cloud-provider-name: external` was not in `/etc/rancher/rke2/config.yaml` at the time. providerID is **immutable** in Kubernetes once set.

**No in-place recovery.** Must `make -C terraform destroy` and re-bring-up with the v3 config in place from the start. VPC stays per #29; full destroy+rebuild is ~15 min.

**Fix landed**: PR #34 (install-do-ccm v3) added `rke2_cloud_provider_name: "external"` default in `ansible/inventory/group_vars/all/main.yml`, rendered into both `rke2_server` and `rke2_agent` `config.yaml.j2` templates. Pairs with PR #30's `rke2_kubelet_args: ["cloud-provider=external"]` — both are needed; either alone is insufficient.

**Portability**:
- The `rke2_cloud_provider_name` flag is RKE2-specific.
- For bare metal with no cloud provider, set it to `""` (empty) so RKE2 manages its own provider integration. Kubelet `--cloud-provider=external` should also be empty.
- The **principle** — set provider-related kubelet/server flags BEFORE first node-join — applies everywhere.

### CCM Ready but does nothing

CCM Deployment is Running but `EXTERNAL-IP` stays `<pending>` and CCM logs show:

```
node_controller.go:288: Error getting instance metadata for node addresses:
  determining droplet ID from providerID: provider ID "rke2://..." is missing
  prefix "digitalocean://"

controller.go:302: failed to ensure load balancer: failed to build load-balancer
  request: no ready nodes available for load balancer
```

**Root cause**: see [Wrong providerID](#wrong-providerid). Fix is same — fresh cluster with correct RKE2 config.

---

## Load Balancer / Network

### LB never provisions

```
$ kubectl -n ingress-nginx get svc ingress-nginx-controller
NAME                       TYPE           ...   EXTERNAL-IP   PORT(S)
ingress-nginx-controller   LoadBalancer   ...   <pending>     80/TCP,443/TCP
```

Multiple possible causes:

1. **No CCM running** — `kubectl -n kube-system get deploy digitalocean-cloud-controller-manager`. If Pending/missing, Flux didn't apply it (sops-age race? CCM Kustomization unhealthy?).
2. **CCM running but Wrong providerID** — see above.
3. **DO PAT scope issue** — `kubectl -n kube-system logs deploy/digitalocean-cloud-controller-manager` should not show 401/403 from DO API. PAT needs LoadBalancer read+write.
4. **Bare metal**: there's no CCM. Use MetalLB, kube-vip, or NodePort-with-external-LB.

### LB public reachability

LB has an IP assigned but `curl https://<canary>` from outside the VPC TLS-handshakes immediately, drops, or hangs.

**Root cause** (test #4 evidence): DO's REGIONAL LB sources backend traffic from outside the worker's VPC CIDR. The default firewall rules allowed only VPC-internal sources on cluster_tcp_ports — the kubelet-allocated NodePort range (30000-32767) wasn't in the allow-list.

**Fix landed**: PR #45 adds an inbound rule for `tcp/30000-32767 from 0.0.0.0/0` in `terraform/modules/do-droplet-infra/firewall.tf`.

**Portability on bare metal**: The DO-firewall layer doesn't exist; you'll have OS-level (`firewalld`, `ufw`, `nftables` directly) or a hardware firewall. Same principle: whatever LB you're using needs to be able to reach worker NodePorts. With MetalLB the LB itself runs inside the cluster so the source IP isn't an external range — different problem class.

### LB type wrong (REGIONAL_NETWORK)

```
$ kubectl get svc ingress-nginx-controller -n ingress-nginx -o yaml | grep loadbalancer-type
  service.beta.kubernetes.io/do-loadbalancer-type: REGIONAL_NETWORK
```

**Root cause**: CCM v0.1.67+ defaults to `REGIONAL_NETWORK` (DO's newer Network LB product). REGIONAL_NETWORK LBs are reachable only inside DO's network, not the public internet.

**Fix landed**: PR #38 set `service.beta.kubernetes.io/do-loadbalancer-type: REGIONAL` explicitly in `apps/ingress-nginx/values.yaml`. Fresh-cluster bring-ups get this from the values.

**Migration recipe (if a cluster has an existing REGIONAL_NETWORK LB)**: PR #55 documents in `docs/runbooks/install-do-ccm.md` (`## Migration: switching LB type` section). Summary:

```bash
kubectl delete helmrelease -n ingress-nginx ingress-nginx
flux reconcile kustomization ingress-nginx --with-source
# wait ~60-120s for new REGIONAL LB to come up at new IP
```

**Portability**: DO-specific annotation. On Hivelocity-with-MetalLB, LB-type wouldn't apply — MetalLB is L2/BGP.

### TLS handshake EOF

```
$ curl https://canary.escapekey.org
curl: (35) TLS connect error: error:0A000126:SSL routines::unexpected eof while reading

$ openssl s_client -connect <LB-IP>:443
write:errno=104
no peer certificate available
```

TCP/443 is OPEN (LB accepts the connection) but every TLS handshake fails immediately with no peer cert exchange.

**Root cause**: LB has no healthy backends. Either:

1. **NodePort firewall blocked** — see [LB public reachability](#lb-public-reachability) above. Fix is PR #45.
2. **ingress-nginx pods not Ready** — `kubectl -n ingress-nginx get pods`.
3. **DO LB backend health-check failing** — DO control panel → LB → Backends tab. Health check defaults to TCP to NodePort; if firewall blocks DO's health-check source from reaching that NodePort, backends are marked unhealthy and LB returns "no backend" → resets connections.

If in-cluster `curl --resolve canary.escapekey.org:443:<Service-ClusterIP>` works but external curl fails, the path break is between DO LB and the workers — firewall, not anything in-cluster.

---

## external-dns

### Orphan TXT

The most persistent operational bug across the test arc.

**Symptom**:
- Canary Ingress applied.
- cert-manager issues cert successfully.
- `dig +short A canary.escapekey.org @ns1.digitalocean.com` returns empty.
- `kubectl -n external-dns logs deploy/external-dns` shows `"All records are already up to date"`.
- `dig +short TXT a-canary.escapekey.org @ns1.digitalocean.com` returns a `heritage=external-dns,external-dns/owner=...` marker.

**Root cause** (issue #44): external-dns's diff logic treats the TXT registry marker as "I own this record name" without verifying that the corresponding A record actually exists. When a stale TXT lingers from a prior test cycle (e.g., the A was deleted out-of-band, or external-dns crashed between deleting A and TXT), the diff says "nothing to do" and the A never gets created.

**Workaround landed**: PR #53 documents the operator recovery recipe in `docs/runbooks/install-do-ccm.md`'s "End-to-end canary" troubleshooting subsection. Quick form (DO API + curl):

```bash
DO_TOKEN=$(sops -d terraform/environments/do-test/secrets.enc.tfvars \
  | grep -E '^do_token\s*=' | sed -E 's/^do_token\s*=\s*"([^"]+)".*/\1/')

# Delete all heritage-tagged external-dns TXT records in the zone:
curl -sS -H "Authorization: Bearer $DO_TOKEN" \
  "https://api.digitalocean.com/v2/domains/escapekey.org/records?type=TXT&per_page=200" \
  | jq -r '.domain_records[] | select(.data | contains("heritage=external-dns")) | .id' \
  | while read id; do
      curl -sS -X DELETE -H "Authorization: Bearer $DO_TOKEN" \
        "https://api.digitalocean.com/v2/domains/escapekey.org/records/$id"
    done

# Re-apply or wait for external-dns's next reconcile (~1 min per PR #51).
```

**Test-#8-validated pre-test prophylactic**: Run the cleanup before each test cycle. external-dns recreates correctly when starting from a clean zone state.

**Partial mitigation landed**: PR #51 dropped the external-dns poll interval from 10m to 1m so orphans auto-resolve faster IF the diff logic ever does notice them. Doesn't fix the diff bug itself.

**Root-cause fix path** (NOT landed): bump external-dns chart to 1.21.1+ → DROPS the in-tree DO provider (chart 1.21+ requires the webhook-based DO provider `digitalocean/external-dns-digitalocean-webhook`). Bigger migration; see issue #44 for the planning.

**Portability**: Cloudflare provider or AWS Route 53 may have different orphan-handling behavior. The diff-logic bug is specific to how external-dns + DO provider interact. On a different DNS provider, you may not see this — but the pre-test cleanup pattern is generally healthy.

### LE rate limited

```
Failed to create Order: 429 urn:ietf:params:acme:error:rateLimited:
  too many certificates (5) already issued for this exact set of identifiers
  in the last 168h0m0s, retry after <future-time>
```

**Root cause**: Let's Encrypt **production** issues at most 5 certificates per identifier set per 168 hours. Test cycles for `canary.escapekey.org` each consume 1 slot. After 5+ tests in a week, hit the limit.

**Fix landed**: PR #54 added `letsencrypt-staging` ClusterIssuer (`apps/cert-manager-custom-resources/clusterissuer.yaml`). Switch the canary Ingress annotation:

```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-staging   # was: letsencrypt
```

Staging certs:
- Are signed by "Fake LE Intermediate" → not browser-trusted (`curl` needs `-k`).
- Exercise the same DNS-01 challenge + DO provider + cert-manager code paths as production.
- Effectively unlimited rate limits.
- Use a different private-key Secret (`tls-staging.key`) so they don't clobber prod.

For anything needing browser-trusted certs (real workloads), switch back to `letsencrypt` for that cert.

**Portability**: Universal cert-manager pattern. Same staging issuer concept works on any cluster, any cloud provider.

### Cert-manager challenge stuck Pending

If `kubectl get challenge -A` shows challenges Pending forever despite cert-manager running:

- DNS-01: external-dns must have created the `_acme-challenge.<host>` TXT record at DO. Check `dig +short TXT _acme-challenge.canary.escapekey.org @ns1.digitalocean.com`. If empty → cert-manager's DO solver has a problem (token missing? PAT scope?).
- HTTP-01: ingress-nginx must serve `/.well-known/acme-challenge/...` on the cert-manager-managed Ingress. Reachability + ingress-class match are the usual culprits.

---

## coredns Pending

If `kubectl -n kube-system get pods -l k8s-app=kube-dns` shows coredns Pending instead of Running, downstream effects cascade:

- Flux source-controller can't resolve github.com → GitRepository never reconciles.
- cert-manager DNS-01 in-cluster lookups fail.
- Any pod-to-Service DNS lookup fails.

**Root cause**: coredns pods don't tolerate the `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint set by `cloud-provider-name=external`. RKE2 manages coredns via the bundled `rke2-coredns` HelmChart, not via Flux — so the Flux-controller toleration patch (PR #39) doesn't reach coredns.

**Fix landed**: PR #46 adds a `HelmChartConfig` override for `rke2-coredns` in `ansible/roles/rke2_server/tasks/main.yml`. The override is dropped into `/var/lib/rancher/rke2/server/manifests/` **before** rke2-server.service starts; RKE2's helm-controller reads it at startup and merges into the coredns chart's values.

Same pattern is used for Canal/Flannel VPC interface binding (`rke2-canal-config.yaml`, the PR #19 baseline). Both fixes follow the same Ansible-managed approach.

**Portability**: RKE2-specific mechanism (the manifests directory pattern). On k0s/kubeadm-on-bare-metal, you'd patch coredns differently. The need for the toleration is universal whenever you use `--cloud-provider=external` with kubelet.

---

## Longhorn

The hard guarantee for this cluster: Longhorn touches ONLY `/var/lib/longhorn` on workers. Enforced by `createDefaultDiskLabeledNodes: true` plus the per-node `node.longhorn.io/create-default-disk=config` label + `node.longhorn.io/default-disks-config` annotation applied by `ansible/roles/longhorn_disk_prep/`. Every troubleshooting decision below preserves that guarantee — never relax it by hand-creating a Longhorn disk on an unlabeled path.

### Longhorn disk isolation broken

```bash
kubectl -n longhorn-system get nodes.longhorn.io -o json \
  | jq -r '.items[].spec.disks | to_entries[] | .value.path' | sort -u
# Expected: exactly one line: /var/lib/longhorn
# Bad: any other path (/, /var/lib, /mnt/something, etc.)
```

**Root cause** (most likely):
1. `defaultSettings.createDefaultDiskLabeledNodes: true` got flipped to `false` in `apps/longhorn/values.yaml`. Without that, Longhorn auto-creates a default disk **on every node it runs on**, using `defaultDataPath` against the node's root filesystem.
2. A node was manually annotated with a different `default-disks-config` path.
3. Operator created a Longhorn disk through the UI on the root filesystem.

**Fix**:
```bash
# 1. Confirm the chart-level setting:
kubectl -n longhorn-system get configmap longhorn-default-setting -o yaml | grep -i createDefault
# Expect: create-default-disk-labeled-nodes: "true"

# 2. Find which Node has the bad path and inspect its annotation:
kubectl get nodes -o json \
  | jq -r '.items[] | "\(.metadata.name): \(.metadata.annotations."node.longhorn.io/default-disks-config" // "<none>")"'

# 3. Delete the offending Longhorn disk from the Node spec (UI or kubectl edit nodes.longhorn.io <node>).
#    DO NOT delete the Node CR -- Longhorn rebuilds it from the annotation on next reconcile.
# 4. Re-apply the Ansible role to overwrite the annotation:
make -C ansible play  # idempotent; longhorn_disk_prep tasks re-annotate.
```

**Portability**: Hivelocity / bare-metal — same mechanism. The opt-in label is provider-agnostic. CPs get neither label nor annotation by Ansible design, so the guarantee holds regardless of substrate.

### Longhorn on CPs

```bash
kubectl -n longhorn-system get nodes.longhorn.io
# Expect 3 rows (workers).
# Bad: 6 rows (workers + CPs).
```

**Root cause**: CPs' `node-role.kubernetes.io/control-plane:NoSchedule` taint was removed (e.g., for a single-node demo) **AND** someone labeled the CPs with `node.longhorn.io/create-default-disk=config`. The DaemonSet now schedules on CPs too. Even without the label they shouldn't auto-create a default disk (the chart's `createDefaultDiskLabeledNodes` gates that), but the manager pods would still run there and consume RAM next to etcd.

**Fix**:
```bash
# 1. Re-taint CPs:
kubectl taint nodes -l node-role.kubernetes.io/control-plane node-role.kubernetes.io/control-plane:NoSchedule --overwrite

# 2. Remove the Longhorn label if present:
kubectl label nodes -l node-role.kubernetes.io/control-plane node.longhorn.io/create-default-disk- --overwrite

# 3. The DaemonSet evicts; the Node CRs disappear.
```

**Portability**: Bare metal — same. The CP-untaint anti-pattern shows up most often in single-node-demo configurations; the Ansible role's "label workers only" stance is the cleanest defense.

### PVC Pending — no schedulable replica

```bash
kubectl get pvc <name> -o jsonpath='{.status.phase}'   # Pending
kubectl describe pvc <name> | tail -20
# Common message: "failed to schedule replicas... no available node"
```

**Diagnostic**:
```bash
kubectl -n longhorn-system get nodes.longhorn.io -o json \
  | jq -r '.items[] | "\(.metadata.name): allowScheduling=\(.spec.allowScheduling) ready=\(.status.conditions[]|select(.type=="Ready")|.status) schedulable=\(.status.conditions[]|select(.type=="Schedulable")|.status)"'
```

Look for `allowScheduling=false` (manually disabled in UI), `ready=False` (manager pod down), or `schedulable=False` (disk full / disk Unschedulable).

**Root causes + fixes**:
- **Disk full**: `defaultSettings.storageMinimalAvailablePercentage` defaults to 25, we set it to 10 — but a 50 GiB volume still becomes Unschedulable below 5 GiB free. Free space or grow the volume (see do-bring-up.md "Resize later").
- **Worker drained or NotReady**: `kubectl get nodes` to confirm. PVC waits for replica anti-affinity (HARD) to find 3 distinct workers. If only 2 workers are Ready, a new 3-replica volume can't bind. Either restore the third worker, or temporarily reduce `defaultClassReplicaCount` (NOT recommended for production data).
- **Disk Unschedulable due to mount loss**: see [Worker boot blocked by Longhorn mount](#worker-boot-blocked-by-longhorn-mount). If `/var/lib/longhorn` lost its mount, the Longhorn Node CR shows the disk Unschedulable.

**Portability**: Universal. Same diagnostic on any substrate.

### longhorn_disk_prep: device missing

```
TASK [longhorn_disk_prep : fail if dedicated Longhorn device is missing] *******
fatal: [do-nyc3-rke2-demo-worker-02]: FAILED! => Dedicated Longhorn device
/dev/disk/by-id/scsi-0DO_Volume_*-longhorn does not exist on
do-nyc3-rke2-demo-worker-02.
```

**Root cause**: Tofu didn't attach the volume (apply failed, volume detached out-of-band, or volume renamed). OR the inventory has a stale `longhorn_device` value.

**Fix**:
```bash
# 1. Confirm Tofu state shows the volume attached:
make -C terraform output worker_longhorn_devices
# Verify the worker that failed has a non-empty value.

# 2. SSH the worker, confirm the device:
ssh <worker> 'ls -l /dev/disk/by-id/scsi-0DO_Volume_*-longhorn'

# 3. If missing on the worker: re-attach via DO UI or `tofu apply` (the volume_attachment resource).
# 4. If Tofu output is empty: re-run `make -C terraform apply` to provision the missing volume.
# 5. Regenerate inventory so render-inventory.py picks up the fresh output:
make -C ansible inventory
```

**Portability**: Bare metal — same role, different device path source (operator-curated, not Tofu output). The Ansible assertion still fails fast with the same actionable message.

### longhorn_disk_prep: non-matching filesystem

```
TASK [longhorn_disk_prep : refuse to wipe a non-matching filesystem] ***********
fatal: [<worker>]: FAILED! => /dev/disk/by-id/scsi-... has an existing
filesystem of type "xfs", not "ext4". Refusing to wipe automatically.
```

**Root cause**: The dedicated volume already has a filesystem of the wrong type (e.g., previously mkfs'd as xfs, or had a Longhorn V2 raw layout in a previous test). The role intentionally refuses to wipe without explicit operator consent.

**Decision tree**:
- **Data is disposable** (most common during cluster tear-downs):
  ```bash
  ssh <worker> 'wipefs -a /dev/disk/by-id/scsi-0DO_Volume_*-longhorn'
  # Re-run the play:
  make -C ansible play
  ```
- **Data is real**: change `longhorn_filesystem` in `ansible/roles/longhorn_disk_prep/defaults/main.yml` to match the existing FS (`xfs`). The role's mount task will then accept the existing FS without mkfs.

**Portability**: Universal — the role's guardrail logic is provider-agnostic.

### Worker boot blocked by Longhorn mount

If a worker fails to boot after Longhorn was enabled:

```
A start job is running for /var/lib/longhorn
[FAILED] Failed to mount /var/lib/longhorn
You are in emergency mode.
```

**Root cause**: The DO volume was detached or renamed *after* fstab was written. Without `nofail`, systemd waits indefinitely or drops to emergency mode.

**Fix landed**: the role writes the fstab entry with `defaults,nofail,noatime`. `nofail` means a missing volume produces a degraded-but-bootable worker. If you're hitting this symptom, the role was modified without `nofail` — restore it:

```bash
ssh <worker>
grep longhorn /etc/fstab
# Expect opts column to include nofail.
# If not, edit and reboot.
```

**While the worker is up but the mount is gone**: Longhorn's Node CR shows the disk Unschedulable. The Volume becomes Degraded (replica missing) but stays R/W from the other 2 workers. Operator action:

```bash
# 1. Reattach or recreate the DO volume.
# 2. Re-run the play to mkfs + mount:
make -C ansible play
# 3. Longhorn auto-rebuilds the missing replica within minutes.
```

**Portability**: Universal. `nofail` is a standard systemd-fstab option; bare-metal workers benefit equally.

### Encrypted SC removed

```bash
kubectl get sc
# Expected: `longhorn (default)`. NO `longhorn-crypto-global`.
```

If a workload expects `longhorn-crypto-global`, it's a leftover from the upstream `fluxcd-template` vendor pattern. Reason it was removed: the upstream-shipped `*.helm_secrets.yaml` for the encrypted SC was encrypted with the upstream maintainer's key — we have no decryption path for it. Rather than vendor a half-working SC, [proposal v2](../openspec/changes/enable-longhorn/proposal.md) cleaned it out.

**Fix** for workloads that need encryption-at-rest: file a new openspec proposal that designs the key-management story explicitly (operator-managed age/LUKS key, key rotation, what cluster components access plaintext, etc.). Do NOT re-vendor the upstream `longhorn-crypto.sc.yaml` blind.

**Portability**: Same on bare metal — the encryption-at-rest decision is independent of substrate.

---

## Pipefail

If a wrapper script reports exit 0 despite the wrapped command obviously failing:

```bash
$ ./some-wrapper.sh
... (failure messages)
$ echo $?
0
```

**Root cause**: the wrapper used `... | tee /log` (or similar). `tee` exits 0 on stdin close, so the pipeline's exit is `tee`'s exit, not the actual command's exit.

**Fix**: Add `set -o pipefail` at the top of the wrapper. Pipeline now exits with the rightmost non-zero exit code.

**Portability**: Universal.

---

## Hivelocity / bare-metal port — what changes

A future cluster running CPs on Hivelocity VPS and workers on bare metal will share most of the above + introduce these substitutions:

### Substitutions

| DigitalOcean component | Hivelocity/BM replacement | Notes |
|---|---|---|
| `digitalocean_droplet` (Tofu) | Hivelocity provider OR manual provisioning | Whatever Hivelocity supports for IaC. For BM workers, often manual rack-and-stack + PXE/iLO config; Tofu support may not exist for bare metal at all. |
| `digitalocean_vpc` | Operator-configured VLAN / SDN | No "default VPC" concept; lifecycle.prevent_destroy not needed, but documenting the IP plan still matters. |
| `digitalocean_firewall` | OS-level (nftables/firewalld) OR hardware firewall | The patterns are the same — allow SSH from operator IPs, allow inter-node VPC traffic, allow LB→NodePort. PR #45's "allow NodePort range from 0.0.0.0/0" might be inappropriate on bare metal; constrain to actual LB source(s). |
| `digitalocean_loadbalancer` (internal kube-API LB) | HAProxy on a VPS, or a hardware LB, or kube-vip in-cluster | DO's internal LB is one option; on BM you'd usually run HAProxy on a dedicated VPS or use kube-vip for the control plane. |
| `digitalocean-cloud-controller-manager` (CCM) | **MetalLB** for LoadBalancer Service provisioning. Possibly **kube-vip** for control-plane VIP. No node-side provider integration. | The big simplification: no providerID-from-cloud, no zone labels, no LB provisioning by CCM. Tradeoff: no rich cloud metadata. |
| `cloud-provider-name: external` in RKE2 config | `""` (empty / unset) — RKE2 manages its own provider integration (none) | Without CCM, leave it empty. Kubelet `--cloud-provider=external` also empty. |
| DO Block Storage volumes (50GB attached, per #11/#12) | Dedicated raw partitions/disks per BM worker | Longhorn's storage model is the same; the substrate provisioning differs. The `longhorn_disk_prep` role's mkfs+mount+label+annotate logic ports directly — only `longhorn_device` host_var sourcing changes (operator-curated inventory instead of Tofu output via `render-inventory.py`). |

### Things that DO carry over

- Repo layout, SOPS-age secrets, GitHub PAT for bootstrap.
- `deploy.sh` and all its fixes (#27, #28, #33, #37, #47, #49, #50) — generic.
- Flux controller tolerations (PR #39) — applies if you use ANY cloud-controller with the `uninitialized` taint, including MetalLB's loadbalancer-controller in some configs.
- coredns toleration (PR #46) — same caveat.
- cert-manager + external-dns + staging issuer (PR #54). DNS provider can stay at DO even if compute moves.
- ingress-nginx — chart works identically; values.yaml needs different annotations for MetalLB (drop DO-specific ones).
- The 4-layer sops-age fix story — universal.
- Project1-dev sed exclusions (PR #27).
- pipefail discipline, `printf 'yes\n...'` patterns.

### New problems likely on bare-metal worker side

- **PXE/network-boot reliability** — outside scope of this doc but a recurring class of issues.
- **Disk identification stability** — `/dev/sd*` names rotate on reboot; use `/dev/disk/by-id/` or by-uuid. Longhorn's per-node disk config needs stable paths. The DO pattern of `/dev/disk/by-id/scsi-0DO_Volume_<name>` has no direct bare-metal analogue; use `/dev/disk/by-id/wwn-<world-wide-name>` or `/dev/disk/by-uuid/<post-mkfs-uuid>`. `longhorn_disk_prep` already uses UUID for the fstab entry (post-mkfs), so the mount is stable across reboots regardless of which by-id path the operator supplies in inventory.
- **IPMI / BMC management** — for power-cycle, console access. Plan operator workflow.
- **No automatic node-replacement** — losing a worker is more work than DO destroy+apply. Plan capacity headroom.

### Things to add to bare-metal openspec proposals when they come

- Network topology diagram (separate from `docs/diagrams/do-network.md`).
- Power/IPMI runbook.
- Disk-naming convention + Ansible facts to discover per-host.
- MetalLB IP pool decision (BGP vs L2; if BGP, ASN coordination with upstream).
- Operator-VPN setup if SSH-from-anywhere isn't acceptable for the BM workers.

---

## Quick-reference recipes (copy-paste friendly)

### Pre-test prophylactic: clean orphan DNS records

```bash
DO_TOKEN=$(sops -d terraform/environments/do-test/secrets.enc.tfvars \
  | grep -E '^do_token\s*=' | sed -E 's/^do_token\s*=\s*"([^"]+)".*/\1/')

curl -sS -H "Authorization: Bearer $DO_TOKEN" \
  "https://api.digitalocean.com/v2/domains/escapekey.org/records?type=TXT&per_page=200" \
  | jq -r '.domain_records[] | select(.data | contains("heritage=external-dns")) | .id' \
  | while read id; do
      curl -sS -X DELETE -H "Authorization: Bearer $DO_TOKEN" \
        "https://api.digitalocean.com/v2/domains/escapekey.org/records/$id"
    done
```

### Manual sops-age unwedge (if deploy.sh fails mid-stride)

```bash
export KUBECONFIG=~/.kube/do-nyc3-rke2-demo
export PATH="$(pwd)/bin/linux-amd64:$PATH"

flux suspend kustomization flux-system
kubectl apply -f flux/flux-system/gotk-sync.yaml
sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -
flux reconcile source git flux-system
flux resume kustomization flux-system
flux reconcile kustomization flux-system
```

### LB type swap (REGIONAL_NETWORK → REGIONAL)

```bash
kubectl delete helmrelease -n ingress-nginx ingress-nginx
flux reconcile kustomization ingress-nginx --with-source
# Watch for new REGIONAL LB IP:
watch -n 5 'kubectl -n ingress-nginx get svc ingress-nginx-controller -o wide'
```

### Force-reconcile every Flux Kustomization

```bash
flux get kustomization -A --no-header | awk '{print $1, $2}' | while read ns name; do
  flux reconcile kustomization "$name" -n "$ns" --timeout 30s 2>&1 | tail -1
done
```

### Watch a fresh bring-up converge

```bash
watch -n 5 '
  echo "=== nodes ===" &&
  kubectl get nodes -o wide --no-headers &&
  echo &&
  echo "=== kustomizations ===" &&
  flux get kustomization -A --no-header | awk "{printf \"%-40s %s\\n\", \$2, \$5}" &&
  echo &&
  echo "=== ingress-nginx LB ===" &&
  kubectl -n ingress-nginx get svc ingress-nginx-controller 2>&1 | tail -1
'
```

---

## See also

- [`docs/runbooks/do-bring-up.md`](runbooks/do-bring-up.md) — canonical Phase-1 substrate bring-up.
- [`docs/runbooks/rke2-install.md`](runbooks/rke2-install.md) — Phase-1 cluster install.
- [`docs/runbooks/fluxcd-bootstrap.md`](runbooks/fluxcd-bootstrap.md) — Phase-3b Flux + apps bring-up.
- [`docs/runbooks/install-do-ccm.md`](runbooks/install-do-ccm.md) — Phase-3d CCM + canary verification.
- [`docs/runbooks/dns-migration-to-do.md`](runbooks/dns-migration-to-do.md) — escapekey.org → DO migration history.
- [`CLAUDE.md`](../CLAUDE.md) — operator/system instructions + access model.
- [`openspec/changes/archive/`](../openspec/changes/archive/) — historical change proposals + design notes.

## PR/issue index — what each fix codified

| Tag | PR | Issue | What |
|---|---|---|---|
| Tofu | #29 | #26 | VPC at env level, prevent_destroy, `make destroy -target='module.infra'` |
| Tofu | #45 | #41 | NodePort 30000-32767 in firewall allow-list |
| Ansible | #34 | #25 | `rke2_cloud_provider_name=external` + group_vars + template render |
| Ansible | #46 | #42 | coredns HelmChartConfig (toleration for uninitialized taint) |
| Ansible | n/a | n/a | (PR #19 baseline) Canal Flannel interface binding to eth1 |
| Flux | #39 | #36 | All six Flux controllers tolerate uninitialized taint |
| deploy.sh | #27 | #23 | `--exclude-dir=archive --exclude-dir=openspec` in do-nyc3-rke2-demo sed |
| deploy.sh | #28 | #24 | Cluster-state-aware bootstrap; reorder sops-age vs decryption-block |
| deploy.sh | #33 | #32 | Branch-mismatch guard at script start |
| deploy.sh | #40 | #37 | Suspend/resume around sops-age + decryption-block window |
| deploy.sh | #48 | #47 | `kubectl apply -f gotk-sync.yaml` while suspended to update in-cluster spec |
| deploy.sh | #50 | #49 | `flux reconcile source git` BEFORE resume to refresh source artifact |
| ingress-nginx | #38 | #35 | `service.beta.kubernetes.io/do-loadbalancer-type: REGIONAL` |
| external-dns | #51 | #44 (partial) | Polling interval 10m → 1m to shrink orphan-TXT window |
| docs | #53 | #44 (workaround) | Orphan-TXT cleanup recipe in install-do-ccm runbook |
| docs | #55 | #43 | LB-type migration recipe in install-do-ccm runbook |
| cert-manager | #54 | #52 | `letsencrypt-staging` ClusterIssuer for repeated test certs |
| docs | #34 | #25 (validation) | install-do-ccm v3 proposal → archived 2026-05-17 |
| Longhorn | (Group 1 PR) | Phase 3c tracking issue | enable-longhorn proposal v2 — V1 filesystem mode, hard-isolation via opt-in labels, Ansible `longhorn_disk_prep` role, removal of upstream-encrypted `longhorn-crypto-global` SC |

Last updated: 2026-05-17 after test #8 + Longhorn Group 1 enablement.
