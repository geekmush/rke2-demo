# RKE2 install runbook

End-to-end operator procedure for bringing up RKE2 on top of the DigitalOcean substrate provisioned by [`docs/runbooks/do-bring-up.md`](do-bring-up.md). Result is a 3-CP HA cluster + 3 workers with the operator able to `kubectl get nodes` from their workstation.

> **Scope.** This runbook covers RKE2 server + agent install and join. It does NOT cover Rancher, Longhorn, FluxCD, or application ingress -- those land in later phases.

## Prerequisites

Operator workstation has:

- Everything from [`do-bring-up.md`](do-bring-up.md) (toolchain, SOPS, age key, DO API token).
- `ansible` and `ansible-playbook` from `uv tool install --with ansible-core ansible`.
- `autossh` for the operator kube tunnel:
  ```bash
  sudo apt install -y autossh
  ```
- `jq` (already a dep of the DO workstation setup).
- The collections in `ansible/requirements.yml` installed:
  ```bash
  make -C ansible requirements
  ```

DigitalOcean side: substrate already applied (`make -C terraform apply`) -- 6 droplets in nyc3 plus the internal CP load balancer.

## One-time setup

### 1. Generate the SOPS-encrypted RKE2 tokens

If `ansible/inventory/group_vars/all/secrets.enc.yaml` doesn't exist yet, create it. Pre-shared tokens make re-rolling cp-01 safe (no bootstrap-dance), and the two-token split (server + agent) limits blast radius if a worker is compromised:

```bash
tmp=$(mktemp --suffix=.yaml)
cat > "$tmp" <<EOF
---
rke2_server_token: "$(openssl rand -hex 32)"
rke2_agent_token:  "$(openssl rand -hex 32)"
EOF
mv "$tmp" ansible/inventory/group_vars/all/secrets.enc.yaml
sops --encrypt --in-place ansible/inventory/group_vars/all/secrets.enc.yaml
grep -q 'ENC\[AES256_GCM' ansible/inventory/group_vars/all/secrets.enc.yaml && echo "encrypted OK"
```

To rotate tokens later, `sops` the file and replace the values; then run `make play` -- RKE2 service restarts as the config changes.

### 2. Render the inventory

```bash
make -C ansible inventory
```

This pipes `tofu output -json` through `ansible/scripts/render-inventory.py` and writes `ansible/inventory/generated.yaml`. The generated file is gitignored -- re-run any time droplets are re-rolled.

## Daily operations

### Plan + apply RKE2 (idempotent)

```bash
make -C ansible play
```

What happens:

1. **`rke2_common`** runs against all 6 hosts -- idempotent OS-prereq replay. Reports `changed=0` on a healthy host.
2. **`rke2_server`** runs serially against `cp-01`, `cp-02`, `cp-03` (in inventory order):
   - probes the internal LB at `https://<cp_endpoint>:9345/ping` to detect an existing cluster
   - cp-01 with no LB response AND no local etcd state -> `cluster-init: true` (bootstrap)
   - everyone else -> `server: https://<cp_endpoint>:9345` (join)
   - writes config, installs RKE2 (pinned version), enables/starts the service
   - waits for `:9345` and `:6443` to respond
   - on the bootstrap CP: fetches `/etc/rancher/rke2/rke2.yaml`, rewrites the `server:` URL to `https://127.0.0.1:6443`, writes it to `~/.kube/rke2-demo` (mode 0600)
3. **`rke2_agent`** runs in parallel on the 3 workers -- install + start.

Expected timing: 7-10 min for a cold install (most of it pulling RKE2 images). A re-run on a healthy cluster is 2-3 min and reports zero changes (other than kubeconfig if you've moved it).

### Reach the cluster from the workstation

The CP load balancer is **internal** (VPC-only, no public IP). Operator `kubectl` reaches it via SSH tunnel.

Start the tunnel (in its own terminal):

```bash
make -C ansible tunnel
```

This invokes `ansible/scripts/kube-tunnel.sh`, which:

- reads the current CP public IPs and the internal LB VPC IP from `tofu output -json`
- runs `autossh` to maintain `localhost:6443` -> `<CP-public>` -> `<LB-VPC>:6443`
- rotates through CPs on failure (single CP outage -> next attempt picks a different jump host)
- Ctrl-C to stop

In another terminal:

```bash
$(make -C ansible kubeconfig | sed -n 's/^export /export /p')
kubectl get nodes -o wide
```

Or do it manually:

```bash
export KUBECONFIG="$HOME/.kube/rke2-demo"
kubectl get nodes -o wide
kubectl get pods -A
```

The kubeconfig's `server:` URL is `https://127.0.0.1:6443`. The cert includes `127.0.0.1` in tls-san by default (RKE2 always does this), so TLS verification works.

### Verify post-apply

Inside the tunnel:

```bash
kubectl --kubeconfig ~/.kube/rke2-demo get nodes
# expect: 3 Ready control-plane,etcd + 3 Ready <none>

kubectl --kubeconfig ~/.kube/rke2-demo -n kube-system get pods | grep etcd
# expect: 3 etcd-* pods, all 1/1 Running

kubectl --kubeconfig ~/.kube/rke2-demo get pods -A --no-headers | awk '$4 != "Running" && $4 != "Completed" {print}'
# expect: nothing
```

### Re-roll a node

Re-rolling a worker (worker-03 in this example):

```bash
tofu -chdir=terraform/environments/do-test taint 'module.infra.digitalocean_droplet.worker[2]'
make -C terraform apply              # destroys worker-03, creates a new one
make -C ansible inventory             # picks up the new IP
make -C ansible play --limit rke2-demo-worker-03
```

Re-rolling a non-bootstrap CP (cp-02 or cp-03) is the same with `digitalocean_droplet.cp[N]` and `--limit rke2-demo-cp-0N`. The role probes the LB, sees the cluster is up, and joins.

Re-rolling cp-01 specifically: same flow. The role checks for local `/var/lib/rancher/rke2/server/db/etcd` -- the recreated cp-01 has no etcd directory, the LB has healthy cp-02/cp-03 backends -> cp-01 takes the `server:` path and joins the existing cluster (rather than re-initing a fresh one).

### Tear down between sessions

To stop droplet billing without destroying state:

```bash
make -C terraform destroy
```

This destroys droplets + LB + firewall + project attachment. **The VPC stays** -- DO marks it as the nyc3 default and refuses deletion. Tofu state remains, ready for the next `make apply`.

After re-apply, droplets have new IPs and the cluster is built fresh -- not a "resume," a full re-bring-up. `make -C ansible inventory && make -C ansible play` reaches the same end state in ~7-10 min.

## Troubleshooting

### `make play` hangs at "wait for kube-apiserver to respond"

cp-01's apiserver isn't responding within 5 minutes. Check the service:

```bash
ssh root@<cp-01-public> systemctl status rke2-server --no-pager
ssh root@<cp-01-public> journalctl -u rke2-server --no-pager -n 60
```

If `journalctl` reports no entries, journal may not be persistent -- run the foreground binary to capture stderr:

```bash
ssh root@<cp-01-public> 'systemctl stop rke2-server; timeout 20 /usr/local/bin/rke2 server 2>&1 | tail -30'
```

Common causes: token mismatch (re-encrypt), bad config (check `cat /etc/rancher/rke2/config.yaml`), VPC routing broken (test `ping <cp-02-private-ip>` from cp-01).

### cp-01 reaches the LB but a joining CP gets `EOF` or `context deadline exceeded`

Almost always a VPC connectivity problem. Test pairwise:

```bash
# from cp-02:
ping -c 2 10.42.0.39       # cp-01 private IP
nc -zv -w 3 10.42.0.39 9345
nc -zv -w 3 10.42.0.41 9345   # internal LB VPC IP
```

If `ping` fails between two CPs but works to a worker, the most likely cause is a routing-table conflict between the VPC CIDR and the CNI's pod CIDR. The fix is to override RKE2's `cluster-cidr` away from the VPC range -- already done in this repo via `inventory/group_vars/all/main.yml`. If it ever regresses, the symptom returns.

### "I rebuilt my workstation -- where's the kubeconfig?"

`~/.kube/rke2-demo` lives in the operator's home directory -- outside the repo working tree -- so a fresh workstation has no copy. Get one by re-running the play; the bootstrap-CP-only fetch fires on every run:

```bash
make -C ansible play
```

Alternatively, copy it directly:

```bash
scp -i ~/.ssh/rke2_demo_ed25519 root@<any-cp-public>:/etc/rancher/rke2/rke2.yaml ~/.kube/rke2-demo
sed -i 's|https://127.0.0.1:6443|https://127.0.0.1:6443|' ~/.kube/rke2-demo  # no-op; safe
chmod 600 ~/.kube/rke2-demo
```

(The kubeconfig is already pointed at `127.0.0.1:6443` -- the `sed` is harmless.)

### The tunnel keeps dropping

`kube-tunnel.sh` rotates across CPs. If one CP is unreachable, you'll see the script move to the next one within ~20s (autossh's `ServerAliveInterval * ServerAliveCountMax`). If *all* CPs are unreachable, check:

- Network from your workstation to DO: `curl -sS https://api.digitalocean.com/v2/account -H "Authorization: Bearer $DO_TOKEN"` works?
- All 3 CPs still exist: `make -C terraform output`
- SSH key in `~/.ssh/rke2_demo_ed25519` matches what was applied: `ssh-keygen -lf ~/.ssh/rke2_demo_ed25519.pub` and compare against `tofu output -json | jq .ssh_key_fingerprint`.

### Lockout fallback (no tunnel path works)

Every CP runs its own `kube-apiserver`. The on-host kubeconfig at `/etc/rancher/rke2/rke2.yaml` points at `https://127.0.0.1:6443` and is admin-credentialed. SSH to any CP and run kubectl there:

```bash
ssh root@<any-cp-public>
KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get nodes
```

This bypasses the tunnel and the LB entirely.

## Future Twingate transition

When the operator workstation grows a Twingate client and we run a Twingate connector inside the VPC:

- The autossh tunnel becomes optional; the connector routes operator traffic to the internal LB's VPC IP directly.
- The kubeconfig stays the same (server URL points at `https://127.0.0.1:6443`) -- or we can re-issue with `https://<LB-VPC>:6443` once the connector is reliable.
- Nothing in the cluster or this runbook needs to change. `make tunnel` becomes a fallback rather than the default path.

## See also

- [`docs/runbooks/do-bring-up.md`](do-bring-up.md) -- droplet substrate
- [`docs/runbooks/secrets.md`](secrets.md) -- SOPS + age operator setup
- [`docs/diagrams/rke2-topology.md`](../diagrams/rke2-topology.md) -- Mermaid of the cluster, tunnel, and join paths
- [`openspec/changes/add-rke2-install/`](../../openspec/changes/add-rke2-install/) -- proposal/design/tasks for this work
