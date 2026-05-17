# Ansible role: `longhorn_node_register`

Companion to [`longhorn_disk_prep`](../longhorn_disk_prep/README.md).
After `rke2_agent` has installed + started the agent (and the kubelet
has registered the Node with the apiserver), this role labels +
annotates the Node so Longhorn opts in to creating a default disk at
`/var/lib/longhorn` (and nowhere else).

## Why split from `longhorn_disk_prep`?

`longhorn_disk_prep` must run BEFORE `rke2_agent` so the mount point
is ready when the kubelet starts. But the node-side kubectl
(`/var/lib/rancher/rke2/bin/kubectl`) doesn't exist until rke2-agent
has been installed. So a single unified role couldn't apply both
phases — split into two roles around the `rke2_agent` boundary.

## Inputs

| Var                   | Default               | Source / required-when |
|-----------------------|-----------------------|------------------------|
| `longhorn_mount_path` | `/var/lib/longhorn`   | `defaults/main.yml`. Must match the value used by `longhorn_disk_prep` on the same host. |

## What it does

1. **Wait for this worker to be a registered Node.** Retries
   `kubectl get node <inventory_hostname>` up to 30× with 5s delay.
   All kubectl operations `delegate_to` the bootstrap CP
   (`groups['rke2_servers'][0]`) because RKE2 agent nodes don't have
   a cluster-admin kubeconfig — only servers do, at
   `/etc/rancher/rke2/rke2.yaml`. `inventory_hostname` continues to
   refer to the original target (the worker) under `delegate_to`.
2. **Label the node** `node.longhorn.io/create-default-disk=config`.
   This is the per-node opt-in for the chart's
   `createDefaultDiskLabeledNodes: true` setting. CPs never receive
   this label, so the OS disk is not in scope.
3. **Annotate the node** `node.longhorn.io/default-disks-config=...`
   with a JSON spec telling Longhorn exactly which path to use, with
   what tags and reservations. Spec:
   `[{"path":"/var/lib/longhorn","allowScheduling":true,"storageReserved":0,"tags":["dedicated"]}]`.

## Idempotency

- Both `kubectl label` and `kubectl annotate` use `--overwrite`;
  re-applying the same value reports `changed=0`.

## Failure modes

- rke2-agent never registers the node within ~2.5 min -> task 1 hits
  its retry timeout. Usually means the upstream `rke2_agent` role
  itself failed and the play is already bailing.
- kubeconfig missing at `/etc/rancher/rke2/rke2.yaml` -> task 1 fails
  immediately. Same root cause as above.

## Bare-metal portability

Provider-agnostic. The role only touches the kube API via the
worker-local kubectl. Same role applies on Hivelocity / bare-metal
workers without modification.
