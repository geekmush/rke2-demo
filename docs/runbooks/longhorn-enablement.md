# Longhorn enablement — operator runbook

Enable, verify, roll back the Longhorn distributed block storage installation on the `do-nyc3-rke2-demo` cluster. Phase 3c.

> **What Longhorn is here.** A CSI driver + DaemonSet that turns the 3× 50 GiB DigitalOcean Block Storage volumes (one per worker, attached as raw block devices by Tofu in Phase 2) into a replicated PV pool for stateful workloads. Replicas are scheduled with hard anti-affinity (3 replicas across 3 distinct workers) so any single worker can lose its volume and the data survives on the other two.

> **Hard isolation.** Longhorn touches ONLY `/var/lib/longhorn` on each worker. The OS disk, any other PVC, any other directory — out of scope. Enforced at two layers: the chart's `createDefaultDiskLabeledNodes: true` plus per-node opt-in labels/annotations applied by the Ansible role. CPs never receive the label, so even if their `NoSchedule` taint is removed, Longhorn physically cannot place a disk on them.

> **Scope.** Phase 3c. Default StorageClass = `longhorn` (plain, 3 replicas, Immediate binding). No encryption-at-rest (the upstream-key-encrypted `longhorn-crypto-global` SC the vendored template shipped was deleted in the enable-longhorn proposal v2 cleanup — see [`openspec/changes/enable-longhorn/`](../../openspec/changes/enable-longhorn/) for the reasoning). No S3 backup target wired up. Both are deferrable to separate future changes.

## Prerequisites

- Cluster up per [`do-bring-up.md`](do-bring-up.md) → [`rke2-install.md`](rke2-install.md) → [`fluxcd-bootstrap.md`](fluxcd-bootstrap.md).
- DO CCM running per [`install-do-ccm.md`](install-do-ccm.md). (Longhorn doesn't need a LoadBalancer Service so CCM isn't a hard prerequisite for Longhorn itself, but the cluster's bring-up sequence assumes CCM is in place since the same `make play` that installs Longhorn's RKE2-level config also depends on the v3 cloud-provider knobs.)
- Tofu output `worker_longhorn_devices` populated. Confirmed by `make -C terraform output worker_longhorn_devices` — returns a 3-entry map of worker hostnames → `/dev/disk/by-id/scsi-0DO_Volume_<name>`.
- Operator-local credentials per [`TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) pre-flight checklist.

## Enable

`./deploy.sh` reconciles `apps/longhorn/` automatically because [`deploy.sh:330`](../../deploy.sh) adds `longhorn.yaml` to the rke2 `app_list`. No manual `kubectl apply` is needed.

Bring-up timeline:

| Time | Event |
|---|---|
| `t+0` | `make -C ansible play` finishes. `longhorn_disk_prep` role has mkfs'd + mounted each worker's 50 GiB volume at `/var/lib/longhorn`, labeled the node `node.longhorn.io/create-default-disk=config`, and annotated it with `default-disks-config`. |
| `t+0..60s` | `./deploy.sh` reconciles. Longhorn HelmRelease installs (DaemonSet + Deployment + CSI driver). |
| `t+60..120s` | CCM untaints nodes (if fresh bring-up — Longhorn DaemonSet pods tolerate `CriticalAddonsOnly` but not `uninitialized` by default; they wait for CCM). Longhorn manager + driver pods Running. |
| `t+120..180s` | Longhorn Node CRs created for the 3 labeled workers (NOT for CPs). Each shows the dedicated disk at `/var/lib/longhorn`. |

## Verify

### 1. Flux Kustomization + HelmRelease healthy

```bash
flux get kustomization -n flux-system longhorn
flux get helmrelease -n longhorn-system longhorn
```

Both `READY True` within ~5 min of `./deploy.sh` first reconcile.

### 2. Longhorn pods Running on workers only

```bash
kubectl -n longhorn-system get pods -o wide
kubectl -n longhorn-system get ds longhorn-manager -o wide
```

`longhorn-manager` DaemonSet should show `DESIRED=3 READY=3` (workers only, NOT CPs — DaemonSet doesn't tolerate the CP `NoSchedule` taint, so it naturally lands only on workers).

### 3. Hard-isolation acceptance gates (NEW for proposal v2)

The headline isolation guarantee. Every Longhorn disk path lives at `/var/lib/longhorn` and **nowhere else**:

```bash
# 3a. Only one disk path across all Longhorn nodes:
kubectl -n longhorn-system get nodes.longhorn.io -o json \
  | jq -r '.items[].spec.disks | to_entries[] | .value.path' | sort -u
# Expect EXACTLY one line: /var/lib/longhorn
```

```bash
# 3b. Only 3 Longhorn Node CRs (workers, NOT CPs):
kubectl -n longhorn-system get nodes.longhorn.io
# Expect 3 rows -- the workers. NOT 6.
```

```bash
# 3c. Disk capacity reflects the dedicated 50 GiB volume,
#     NOT the 80 GiB droplet OS disk:
kubectl -n longhorn-system get nodes.longhorn.io -o json \
  | jq -r '.items[] | "\(.metadata.name): \(.status.diskStatus[].storageMaximum / 1073741824 | floor) GiB"'
# Expect ~50 GiB per worker (give or take FS overhead).
```

```bash
# 3d. On each worker, confirm the mount lineage:
ssh worker-N 'findmnt /var/lib/longhorn; lsblk -f | head -20'
# Expect: mounted from /dev/sda or /dev/sdb (the DO volume),
#         NOT /dev/vda (the OS disk).
#         Fstab entry uses UUID=..., opts include nofail.
```

If any of 3a-3d fail, **stop**: the proposal's hard-isolation guarantee isn't holding. Triage path: check the worker's `node.longhorn.io/create-default-disk` label + `default-disks-config` annotation (Ansible role tasks 6+7), check the values.yaml `createDefaultDiskLabeledNodes: true` setting, check that `defaultSettings.defaultDataPath` is `/var/lib/longhorn`.

### 4. Default StorageClass

```bash
kubectl get sc
```

Expect:
- `longhorn (default)` — plain, replicaCount=3.
- (NO `longhorn-crypto-global` — deleted in proposal v2 cleanup.)

### 5. End-to-end PVC + replica anti-affinity

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: lh-smoke, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
EOF

# PVC binds within ~30s:
kubectl get pvc lh-smoke -w

# 3 replicas, distinct nodes:
kubectl -n longhorn-system get replicas.longhorn.io \
  -l longhornvolume=$(kubectl get pvc lh-smoke -o jsonpath='{.spec.volumeName}') \
  -o jsonpath='{range .items[*]}{.spec.nodeID}{"\n"}{end}' | sort -u
# Expect 3 distinct worker names.
```

### 6. Stateful pod survives reschedule

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: { name: lh-writer, namespace: default }
spec:
  containers:
    - name: writer
      image: busybox:latest
      command: ["sh","-c","echo 'longhorn replica survival check' > /data/proof; sleep 3600"]
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: lh-smoke }
EOF

kubectl wait pod lh-writer --for=condition=Ready --timeout=60s
ORIG_NODE=$(kubectl get pod lh-writer -o jsonpath='{.spec.nodeName}')
echo "ran on: $ORIG_NODE"

# Force-delete, reschedule, read the file back:
kubectl delete pod lh-writer --grace-period=0 --force
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: { name: lh-reader, namespace: default }
spec:
  containers:
    - name: reader
      image: busybox:latest
      command: ["cat","/data/proof"]
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: lh-smoke }
EOF

kubectl wait pod lh-reader --for=condition=Ready --timeout=60s || true
kubectl logs lh-reader
# Expect: "longhorn replica survival check"
NEW_NODE=$(kubectl get pod lh-reader -o jsonpath='{.spec.nodeName}')
echo "rescheduled to: $NEW_NODE"
```

Tear-down:
```bash
kubectl delete pod lh-reader --grace-period=0 --force
kubectl delete pvc lh-smoke
# Longhorn reaps the Volume within ~30s:
kubectl -n longhorn-system get volumes.longhorn.io
```

## Rollback

If Longhorn turns out to be causing problems:

```bash
# 1. Remove longhorn.yaml from deploy.sh's rke2 app_list (or change to "").
# 2. Reconcile so Flux removes the HelmRelease:
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# 3. Confirm Longhorn is gone:
kubectl -n longhorn-system get pods   # should be empty
kubectl get crds | grep longhorn      # should be empty
kubectl get sc                        # `longhorn` SC gone
```

Volume data on the dedicated 50 GiB disks survives the rollback (it's still ext4 on the DO volume, just not exposed via a Longhorn replica anymore). To fully reclaim the disks: `umount /var/lib/longhorn` on each worker + comment the fstab line; the disks stay attached at the DO level and can be reused by a future re-enablement or wiped via `wipefs -a /dev/disk/by-id/scsi-0DO_Volume_<name>`.

## Cost

Volume cost ~$0.10/GiB-month × 50 × 3 = **~$15/month** while volumes exist. Volumes persist across `make destroy` (they're DO Block Storage, not droplet ephemeral). Manual delete via DO console / API to stop the spend.

## Deferred to future changes

- **Encryption-at-rest StorageClass** — the upstream `longhorn-crypto-global` was deleted in proposal v2 cleanup (its required Secret was SOPS-encrypted with an upstream key we can't decrypt). When a workload actually needs encryption-at-rest, a new proposal designs key-management explicitly.
- **S3 backup target** (Longhorn → DO Spaces or external S3). Currently no backup target configured; Longhorn can take in-cluster snapshots but can't ship them off-cluster. Separate proposal.
- **V2 data engine** (block-mode against the raw disk, no filesystem). Tech Preview in Longhorn 1.11; requires kernel/hugepages/CPU prereqs our `s-4vcpu-8gb` workers don't have headroom for. Revisit when V2 GAs and a workload demands the perf.

## See also

- [`openspec/changes/enable-longhorn/proposal.md`](../../openspec/changes/enable-longhorn/proposal.md) — why + decisions + success criteria.
- [`openspec/changes/enable-longhorn/design.md`](../../openspec/changes/enable-longhorn/design.md) — file layout + hard-isolation mechanism details.
- [`docs/diagrams/longhorn-topology.md`](../diagrams/longhorn-topology.md) — DO volume → ext4 → mount → Longhorn replica → PVC chain.
- [`docs/TROUBLESHOOTING.md`](../TROUBLESHOOTING.md) — symptom-indexed reference (includes a Longhorn section).
- [`docs/runbooks/do-bring-up.md`](do-bring-up.md) — Phase 2 substrate (where the 50 GiB volumes get provisioned).
- [`ansible/roles/longhorn_disk_prep/README.md`](../../ansible/roles/longhorn_disk_prep/README.md) — Ansible role details.
