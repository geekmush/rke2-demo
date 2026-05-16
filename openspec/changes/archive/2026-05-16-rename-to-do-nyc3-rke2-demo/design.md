# Design — rename-to-do-nyc3-rke2-demo

**Tracking issue:** [#20](https://github.com/geekmush/do-nyc3-rke2-demo/issues/20)

## Three-name separation

Until this change, three identities were conflated:

- GitHub repo name
- Local directory name
- Cluster name

Going forward they share the new identity (`do-nyc3-rke2-demo`), but the concept of "they could be different" stays clear: e.g. a future operator could check out the repo into `~/work/rke2-cluster-1/` and still have everything function -- the cluster name (= `cluster_name` variable in Ansible + Tofu `project_name`) is what drives downstream resource naming, kubeconfig paths, and DNS owner IDs.

## What changes

Categorized by impact + reversibility:

### Behavioral (cluster won't work if mismatched)

| File | Change |
|---|---|
| `variables.sh` | `cluster_name=do-nyc3-rke2-demo` + `git_repo=do-nyc3-rke2-demo` |
| `terraform/environments/do-test/variables.tf` | `project_name` default `"do-nyc3-rke2-demo"` |
| `terraform/environments/do-test/terraform.tfvars.example` | Comment showing default `project_name` updated |
| `ansible/inventory/group_vars/all/main.yml` | `cluster_name: do-nyc3-rke2-demo` |
| `apps/external-dns/values.yaml` | `txtOwnerId: do-nyc3-rke2-demo` |
| `ansible/scripts/render-inventory.py` | Default `--key` path |
| `ansible/scripts/kube-tunnel.sh` | SSH key default |

The `cluster_name` Ansible variable feeds `operator_kubeconfig_path` (`~/.kube/{{ cluster_name }}`), so kubeconfig moves from `~/.kube/rke2-demo` to `~/.kube/do-nyc3-rke2-demo` automatically. Operator's existing `~/.kube/rke2-demo` is stale (yesterday's cluster destroyed) and was already deleted as part of the shutdown checklist; no leftover state collision.

The Tofu `project_name` default feeds resource naming via `format("%s-cp-%02d", var.project_name, ...)` etc., so DO resources come up as `do-nyc3-rke2-demo-cp-01`, `do-nyc3-rke2-demo-worker-01-longhorn`, `do-nyc3-rke2-demo-cp` (LB), etc.

### Vendored upstream files

These were touched during Phase 3a with `s/do-nyc3-rke2-demo/rke2-demo/g`. Now we do the same shape:

```bash
find apps variables.sh \
  -type f \( -name '*.yaml' -o -name '*.sh' \) \
  -exec sed -i 's/rke2-demo/do-nyc3-rke2-demo/g' {} +
```

(Excluding `deploy.sh` -- same reasoning as Phase 3a; deploy.sh has its own runtime rewrite logic that should see an already-renamed tree as a no-op.)

Files touched: `apps/external-dns/values.yaml` (txtOwnerId), `apps/metallb-custom-resources/api-endpointslice.yaml`, `apps/metallb-custom-resources/ipaddresspools.yaml`, `apps/metallb-custom-resources/l2advertisements.yaml`, `apps/nxrm-ha/values.yaml`, `variables.sh`.

### Documentation

Bulk rewrite via `sed` across `docs/runbooks/`, `docs/diagrams/`, `README.md`, `CLAUDE.md`, `terraform/README.md`. Then a manual sweep for places where the old name is contextually correct (e.g. discussing the rename itself).

### SSH key path references

Two scripts hardcode `~/.ssh/rke2_demo_ed25519`:

- `ansible/scripts/render-inventory.py` -- default `--key` argument value
- `ansible/scripts/kube-tunnel.sh` -- `${RKE2_SSH_KEY:-$HOME/.ssh/rke2_demo_ed25519}` default fallback

Updated to `~/.ssh/do_nyc3_rke2_demo_ed25519` (underscores, matching the SSH-key naming convention). Operator already did `mv` on the keys.

## What does NOT change

- **DO Project** named `"RKE2"` in DO UI. `do_project_name = "RKE2"` in Tofu unchanged. Generic project grouping; not cluster-specific.
- **DNS subdomain** `rke2-demo.escapekey.org`. Already delegated to DO DNS. Renaming would require new Dreamhost NS records + new DO zone. Operator separately investigating moving all of escapekey.org's DNS to DO; this rename is independent.
- **`.sops.yaml` age recipient**. Operator-identity key, not cluster-identity. Unchanged.
- **DO API token** (in `terraform/environments/do-test/secrets.enc.tfvars`). Operator-account-scoped, not cluster-scoped. Unchanged.
- **Archived OpenSpec records** in `openspec/changes/archive/`. Historical artifacts; retroactive renaming makes them lie.
- **`.claude/memory/`**. Per-decision history; retroactive renaming hides the trail of when the name was `rke2-demo`.
- **Past commit messages and PR titles**. Immutable history.
- **`docs/upstream/fluxcd-template-README.md`**. Archived upstream copy.

## Risks / open questions

- **DO Project membership**: existing droplets/volumes/LBs were attached to the "RKE2" project via `digitalocean_project_resources`. New resources after this PR (named `do-nyc3-rke2-demo-*`) get attached to the same project. Net: project's contents change names; project itself doesn't move. Acceptable.
- **`txtOwnerId` change after a partial-deploy state**: not relevant here -- the cluster was destroyed yesterday before any DNS records were created via external-dns. Fresh deploy under the new ID has no historical ownership conflict.
- **Future bare-metal cluster naming**: This change picks a convention. Phase 4 should follow it (e.g. `bm-onprem-rke2-prod` or `bm-rack42-rke2-prod`). Document the convention in CLAUDE.md so it doesn't drift.
- **Operator's `~/.ssh/known_hosts.rke2demo`**: stale entries for yesterday's destroyed droplets. Already cleaned per the shutdown checklist; new droplets accept fresh keys via `StrictHostKeyChecking=accept-new`.

## Hand-off contract to the next bring-up

After this PR merges:

1. `make -C terraform apply` -- creates resources as `do-nyc3-rke2-demo-*`.
2. `make -C ansible inventory && make -C ansible play` -- installs RKE2 (including the Phase-1 Flannel iface fix from PR #19); kubeconfig lands at `~/.kube/do-nyc3-rke2-demo`.
3. `source variables.sh && export GITHUB_TOKEN=... && ./deploy.sh` -- bootstraps Flux. `txtOwnerId: do-nyc3-rke2-demo` becomes the external-dns identity; deploy key on the GitHub repo gets recreated (assumes operator revoked yesterday's per the shutdown checklist).
4. Verify per Phase 3b runbook.

Phase 3c (Longhorn) follows in a separate change once tomorrow's cluster is verified under the new identity.
