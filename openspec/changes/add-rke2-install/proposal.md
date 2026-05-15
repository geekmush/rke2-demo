# Proposal — add-rke2-install

**Tracking issue:** [#6](https://github.com/geekmush/rke2-demo/issues/6)
**Phase:** 1 — DO bring-up
**Status:** proposed

## Why

The droplet substrate from `add-do-droplet-module` exists and the cloud-init regression (#4) is fixed. The next layer of Phase 1 is the actual RKE2 cluster. This change also introduces the Ansible scaffolding that every subsequent change in this repo will reuse — `roles/`, `playbooks/`, `inventory/`, `group_vars/`, the SOPS integration, the `tofu output -> inventory` rendering pipeline. Per groundrule #3, deploys are Ansible-maintainable; this is where that materializes.

Per groundrule #5, end-state app delivery is FluxCD on top of Rancher on top of RKE2. This change is the RKE2 layer.

## What this change ships

- **Ansible scaffolding** at `ansible/`:
  - `roles/rke2_common` — idempotent OS prereqs that replay cloud-init's work.
  - `roles/rke2_server` — installs and starts RKE2 server on CP nodes; bootstrap-vs-join logic; fetches the operator kubeconfig from the bootstrap CP and rewrites its server URL to `https://127.0.0.1:6443` for SSH-tunnel use.
  - `roles/rke2_agent` — installs and starts RKE2 agent on worker nodes.
  - `playbooks/site.yml` — orchestrates common -> bootstrap CP -> other CPs (serial: 1) -> workers, in that order.
  - `inventory/` + `scripts/render-inventory.py` — generator that consumes `tofu output -json` and writes `inventory/generated.yaml` (gitignored).
  - `inventory/group_vars/all/main.yml` — non-secret defaults (RKE2 version pin, disabled addons, cluster/service CIDR overrides, port constants).
  - `inventory/group_vars/all/secrets.enc.yaml` — SOPS-encrypted `rke2_server_token` and `rke2_agent_token`.
  - `scripts/kube-tunnel.sh` — `autossh`-backed SSH tunnel wrapper for operator kubectl. Rotates across all healthy CPs as jump hosts on failure; reads CP public IPs and the internal LB VPC IP from `tofu output -json` on every reconnect.
  - `ansible.cfg` (with `community.sops` vars plugin enabled for `*.enc.*`), `requirements.yml`, `Makefile` (targets: `requirements`, `inventory`, `play`, `play-check`, `kubeconfig`, `tunnel`, `lint`).
- **One new Tofu resource**:
  - `digitalocean_loadbalancer` with **`network = "INTERNAL"`** in front of the 3 CPs on TCP/6443 and TCP/9345. No public IP, no firewall ACL needed. Module output `cp_endpoint` exposes the LB's VPC IP.
- **Pinned RKE2 version** in `inventory/group_vars/all/main.yml`.
- **CNI CIDR overrides**: `cluster-cidr: 10.244.0.0/16` and `service-cidr: 10.245.0.0/16`. RKE2's defaults (10.42.0.0/16 / 10.43.0.0/16) overlap the existing nyc3 default VPC at `10.42.0.0/20`. Overlapping CIDRs cause CNI routes to shadow VPC routes in the kernel routing table; symptom is inter-droplet VPC traffic failing with `RTNETLINK answers: Invalid argument`. The VPC itself can't be moved because DO marks our VPC as nyc3's default and refuses both deletion and demotion.
- **Disabled component**: `rke2-ingress-nginx` (FluxCD installs ingress in Phase 3). All other RKE2 addon defaults left as-is.
- **Docs**:
  - `docs/runbooks/rke2-install.md` — end-to-end procedure.
  - `docs/diagrams/rke2-topology.md` — Mermaid: operator -> autossh -> jump CP -> internal LB -> CP backends; etcd quorum among CPs; kubeconfig retrieval flow.
  - Top-level `README.md` "Getting started" chains `do-bring-up` -> `rke2-install`.

## Out of scope (explicit non-goals)

- No Rancher install — separate change.
- No Longhorn — Phase 2.
- No FluxCD bootstrap — Phase 3.
- No CNI swap (Cilium / etc.) — flannel default only.
- No CIS hardening pass.
- No off-box etcd snapshots. RKE2 default snapshot retention is on; copying snapshots to DO Spaces is a follow-up issue.
- No ansible-lint in CI (no CI workflow exists yet); local `make lint` is in scope.

## Decisions locked in

Reached through review on 2026-05-14 and refined during implementation on 2026-05-15 once we hit DO LB source-IP-preservation and VPC-default-policy constraints. See `design.md` for the discovery trail.

1. **CP endpoint** = DO Load Balancer fronting 3 CPs. Alternative considered: pinning to cp-01's private IP. Rejected because it makes cp-01 a SPOF for new joins and forces architectural rework when Phase 4 swaps to kube-vip.
2. **Inventory** = static rendering via `ansible/scripts/render-inventory.py` from `tofu output -json`. Alternative considered: `community.general.terraform_state` plugin. Rejected because the plugin reads state directly -- once remote state lands (#3), the plugin needs Spaces creds at every play invocation. The static render takes a snapshot at a known moment and is GitOps-friendly.
3. **Scope** = LB-in-Tofu + Ansible scaffolding + RKE2 install bundled in one change. Alternative considered: splitting the LB out as a tiny precursor change. Rejected because the LB earns its keep only when consumed by RKE2.
4. **LB is INTERNAL, not EXTERNAL.** Original design had an EXTERNAL LB with an operator-managed CIDR allowlist for direct `kubectl` from the workstation. That broke because DO LBs preserve the client source IP when forwarding TCP traffic, so droplet-firewall-side restrictions on `6443`/`9345` (VPC-internal only, per CLAUDE.md access model) dropped the LB-forwarded traffic. Workarounds were possible (loosen droplet firewall or run two LBs), but Twingate is the longer-term operator-access path AND the application-ingress LB is a separate Phase 3 resource -- this LB has no long-term external role. Switching to `network = "INTERNAL"` keeps the access model intact, drops the entire allowlist mechanism, and stays useful forever for CP-to-CP and worker join traffic. The LB becomes obsolete only when Phase 4 bare-metal swaps it for kube-vip.
5. **Operator kube access pre-Twingate** = SSH tunnel from workstation through any healthy CP to the internal LB's VPC IP, managed by `ansible/scripts/kube-tunnel.sh` (autossh wrapper with CP rotation). Kubeconfig points at `https://127.0.0.1:6443`. Recovery if the chosen CP dies mid-session: autossh respawns; if the same host stays down, the rotation moves on after ~30s. Operator's redundancy comes from the rotation, not from the LB being on the public internet.
6. **Cluster + service CIDRs overridden** to `10.244.0.0/16` / `10.245.0.0/16`. RKE2's defaults overlap the VPC's `10.42.0.0/20` and shadow VPC routes; we can't move the VPC because DO refuses to delete or demote the nyc3 default VPC.

## Success criteria

- `make plan` shows the new LB and `cp_endpoint` output.
- `make apply` creates the LB without touching the droplets (LB is an additive resource).
- `make -C ansible inventory` writes a valid `inventory/generated.yaml` from current Tofu outputs.
- `make -C ansible play` brings up a healthy RKE2 cluster end-to-end from a fresh apply.
- With the kube tunnel running (`make -C ansible tunnel`), `kubectl --kubeconfig ansible/artifacts/kubeconfig get nodes -o wide` shows 6 nodes Ready (3 control-plane, 3 worker), all on the VPC private network.
- All 3 etcd pods healthy in `kube-system`.
- `kubectl get pods -A` — no `CrashLoopBackOff`; no `Pending` beyond what RKE2 expects.
- Re-running `make -C ansible play` is idempotent (no changes reported by Ansible).
- Diff contains zero plaintext secrets. Server and agent tokens live in `secrets.enc.yaml` only.
- Docs land per groundrule #7.

## Tracking

Issue #6. Does not block on #3 (remote state) — local state is fine for this work.
