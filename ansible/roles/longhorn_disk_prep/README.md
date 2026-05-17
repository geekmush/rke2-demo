# Ansible role: `longhorn_disk_prep`

Prepares a dedicated raw block device on a worker node for Longhorn
consumption (mkfs + UUID-mount at `/var/lib/longhorn`). The companion
role `longhorn_node_register` runs AFTER `rke2_agent` to apply the
Longhorn opt-in label + default-disks-config annotation.

## Inputs

| Var                   | Default               | Source / required-when |
|-----------------------|-----------------------|------------------------|
| `longhorn_device`     | (no default)          | Per-host from inventory (emitted by `render-inventory.py` from Tofu output `worker_longhorn_devices`). Must be a stable `/dev/disk/by-id/...` path. **REQUIRED** -- role fails fast at task 1 if missing. |
| `longhorn_mount_path` | `/var/lib/longhorn`   | `defaults/main.yml`. Matches Longhorn chart default. |
| `longhorn_filesystem` | `ext4`                | `defaults/main.yml`. If the device already has a different filesystem, role fails (operator decision required, no automatic wipe). |

## What it does

In order:

1. **Stat the device.** Fail with a clear message if the path doesn't
   exist. Means either Phase 2 (DO Block Storage volumes) didn't run,
   or the by-id path changed (rare on DO).
2. **Inspect existing filesystem.** If the device already has
   `longhorn_filesystem`, skip mkfs. If it has a different filesystem,
   fail loudly.
3. **mkfs.ext4** (or whatever `longhorn_filesystem` is) only if no FS
   present. `force: false` so we never wipe accidentally.
4. **Mount via UUID** at `/var/lib/longhorn`. Persists in `/etc/fstab`
   with `nofail,noatime` -- a missing volume produces a degraded but
   bootable worker rather than blocking boot entirely.
5. **`chmod 0700 root:root`** on the mount point. Longhorn runs
   privileged anyway; tighter perms reduce blast radius.

Node-side opt-in (label + default-disks-config annotation) is handled
by [`longhorn_node_register`](../longhorn_node_register/README.md),
which must run AFTER `rke2_agent` because it needs
`/var/lib/rancher/rke2/bin/kubectl` -- a binary that doesn't exist
until rke2-agent has been installed.

## Why UUID-based mount, not the by-id path?

DO's `/dev/disk/by-id/scsi-0DO_Volume_<name>` is stable across reboots
*as long as* the volume name doesn't change. DO volume rename is
rare but possible (operator-initiated, via the DO control panel or
API). UUIDs are stable across rename AND across re-import.

The role still uses the by-id path for the initial mkfs decision (the
input from Tofu is deterministic; the UUID doesn't exist until after
mkfs). It indirects through `blkid` to UUID immediately for the mount
line.

## Playbook placement

Workers-only. Must run BEFORE `rke2_agent` so the mount point is ready
when the kubelet starts.

```yaml
# ansible/playbooks/site.yml (snippet)
- name: RKE2 agent (workers)
  hosts: rke2_agents
  roles:
    - longhorn_disk_prep        # disk: mkfs + mount    (BEFORE rke2_agent)
    - rke2_agent                # cluster: install + start
    - longhorn_node_register    # node: label + annotate (AFTER rke2_agent)
```

## Idempotency

- Task 3 (mkfs): no-op if FS already present.
- Task 4 (mount): no-op if already mounted at the desired path with
  matching options.
- Task 5 (chmod): no-op if perms already 0700.

Second `make play` after a clean first one reports `changed=0`.

## Failure modes

- `longhorn_device` host_var missing -> task 1 errors with a clear
  message about inventory.
- Device exists but has wrong filesystem type -> task 2 fails. Operator
  must `wipefs` (or rebuild the volume from Tofu) before re-running.

## Bare-metal portability

The role takes a single device-path input. For Phase 4 (bare-metal):

- Set `longhorn_device` from a per-host hardware-inventory fact
  (e.g., a discovered `/dev/disk/by-id/wwn-0x...`), NOT from Tofu output.
- Possibly switch `longhorn_filesystem` to `xfs` for very large disks.
- Everything from the mount point down (Longhorn values, StorageClass,
  replica policy) is provider-agnostic.

See `openspec/changes/enable-longhorn/design.md` "Hand-off contract to
Phase 4" section.
