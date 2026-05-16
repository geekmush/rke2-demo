# DigitalOcean bring-up runbook

End-to-end operator procedure for provisioning the Phase 1 RKE2 substrate on DigitalOcean using the OpenTofu module at `terraform/modules/do-droplet-infra/`.

> **Scope.** This runbook covers VPC + firewall + SSH key + 6 droplets (3 CP, 3 worker) with OS prereqs applied via cloud-init. **No RKE2, Rancher, or Longhorn is installed here.** Those land in subsequent changes.

## Prerequisites

Operator workstation has:

- `tofu` ≥ 1.8.0 (verify: `tofu version`)
- `sops` + `age` (verify: `sops --version && age --version`)
- A working SOPS keyring at `~/.config/sops/age/keys.txt` whose public key is listed in `.sops.yaml`
- `make` and `mktemp` (standard on any Linux/macOS workstation)

DigitalOcean account has:

- Billing configured.
- An API token with — at minimum — read+write on: `droplet`, `vpc`, `firewall`, `ssh_key`, `tag`, plus read on `image`, `region`, `account`. Add `project:read` + `project:update` if you plan to attach droplets to a DO Project (default).
- (Optional) A Project to organize resources — created out-of-band in the UI. Default name in `terraform.tfvars.example` is `RKE2`. Set `do_project_name = null` to skip attachment entirely.

You have:

- An OpenSSH **public** key string for the operator key. Generate one if needed:
  ```bash
  ssh-keygen -t ed25519 -C "do-nyc3-rke2-demo operator" -f ~/.ssh/do_nyc3_rke2_demo_ed25519
  cat ~/.ssh/do_nyc3_rke2_demo_ed25519.pub
  ```
  Back up the private key out-of-band — losing it means re-rolling droplets to get back in.

## One-time setup

### 1. Encrypt the DO API token into the env

Pattern: write plaintext to a path outside the working tree, move into the repo, encrypt in place, verify, delete any plaintext copy.

```bash
cd terraform/environments/do-test

# Write plaintext OUTSIDE the working tree.
tmp=$(mktemp --suffix=.tfvars)
cat > "$tmp" <<'EOF'
do_token = "dop_v1_PASTE_TOKEN_HERE"
EOF

# Move into repo path, then encrypt in place.
mv "$tmp" secrets.enc.tfvars
sops --encrypt --in-place secrets.enc.tfvars

# Verify it's encrypted (you should see ENC[AES256_GCM,...] blobs).
grep -q 'ENC\[AES256_GCM' secrets.enc.tfvars && echo "encrypted OK"

cd ../../..
```

To update the token later (e.g. rotation):

```bash
sops terraform/environments/do-test/secrets.enc.tfvars
# Opens decrypted in $EDITOR; saves re-encrypted.
```

### 2. Author the non-secret tfvars

```bash
cd terraform/environments/do-test
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and paste your SSH public key into ssh_pubkey.
```

`terraform.tfvars` is `.gitignore`d. Only `terraform.tfvars.example` is committed.

### 3. Initialize Tofu

From the `terraform/` directory:

```bash
make init
```

This runs `tofu init -upgrade`, downloads the DigitalOcean provider, and writes `.terraform.lock.hcl` (committable; covered later in the implementation tasks).

## Daily operations

All `make` targets below run from the `terraform/` directory.

### Plan

```bash
make plan
```

What this does:

1. Verifies `tofu`/`sops` on PATH, that `secrets.enc.tfvars` and `terraform.tfvars` both exist.
2. Decrypts `secrets.enc.tfvars` to a `mktemp` file.
3. Runs `tofu plan` against both var files, writes the plan to `tfplan.bin`.
4. Removes the decrypted temp file via shell `trap` — runs on success **and** failure.

Expected resource counts on a clean apply:

- 1 × `digitalocean_vpc`
- 1 × `digitalocean_ssh_key`
- 1 × `digitalocean_firewall`
- 6 × `digitalocean_droplet` (3 CP + 3 worker)
- 1 × `digitalocean_project_resources` (if `do_project_name` is set)

Review the plan output carefully before applying. In particular: confirm VPC CIDR, region, droplet sizes, and that the firewall rules match the access model (SSH 22 to `0.0.0.0/0`, everything else VPC-internal).

### Apply

```bash
make apply
```

Prompts for `yes` confirmation before creating resources. Takes ~3–5 minutes for all six droplets to provision and finish first-boot cloud-init.

### Verify post-apply

```bash
make output                # show outputs (IPs, IDs, fingerprint)

# Pick a node and SSH in (replace IP with one from `make output`).
ssh -i ~/.ssh/do_nyc3_rke2_demo_ed25519 root@<public_ip>

# On the droplet — confirm cloud-init ran:
sudo swapon --show                                  # empty == swap off OK
lsmod | grep -E 'br_netfilter|overlay'              # both loaded
sysctl net.bridge.bridge-nf-call-iptables           # = 1
sysctl net.ipv4.ip_forward                          # = 1
grep -h Password /etc/ssh/sshd_config.d/*.conf      # PasswordAuthentication no
```

### Phase 2 storage substrate (DO Block Storage volumes)

After the droplet apply, the Tofu module also provisions **one 50 GB DigitalOcean Block Storage volume per worker** (three volumes, ~$15/month at $0.10/GB-month). Volumes are attached to the workers but left **raw**: no filesystem, no mount. Longhorn (installed by FluxCD in Phase 3) consumes them in block-device mode -- the more efficient path -- which requires the disks to stay un-formatted.

Stable device paths are surfaced as a Tofu output:

```bash
make -C terraform output worker_longhorn_devices
# {
#   "do-nyc3-rke2-demo-worker-01" = "/dev/disk/by-id/scsi-0DO_Volume_do-nyc3-rke2-demo-worker-01-longhorn"
#   "do-nyc3-rke2-demo-worker-02" = "/dev/disk/by-id/scsi-0DO_Volume_do-nyc3-rke2-demo-worker-02-longhorn"
#   "do-nyc3-rke2-demo-worker-03" = "/dev/disk/by-id/scsi-0DO_Volume_do-nyc3-rke2-demo-worker-03-longhorn"
# }
```

Verify on a worker:

```bash
ssh -i ~/.ssh/do_nyc3_rke2_demo_ed25519 root@<worker-public-ip>
lsblk                                                          # expect a 50G sda with no MOUNTPOINTS
ls -l /dev/disk/by-id/scsi-0DO_Volume_*-longhorn               # symlink resolves to /dev/sda
mount | grep sda                                               # nothing -- raw, unmounted
```

If `lsblk` shows a filesystem or mount on the new disk, something pre-formatted it -- check `cloud-init.yaml.tftpl` for unintended changes and `digitalocean_volume.longhorn`'s `initial_filesystem_type` (must stay `null`).

**Resize later (non-destructive):** bump `var.longhorn_volume_size_gb` in `terraform/environments/do-test/terraform.tfvars`; `make apply`. DO grows the volume in place. Longhorn (once installed) needs a manual disk-resize through its UI/API to consume the new space.

**Destroy semantics:** `make -C terraform destroy` removes the volumes too. Once Longhorn is installed and holding data, that data is **gone** with the volumes. Phase 3 will document Longhorn's snapshot/backup target setup so destroy is recoverable.

### Destroy (between sessions)

Six droplets at the test sizes cost ~$0.30/hour. Tear down when you're not actively working:

```bash
make destroy
```

State is preserved locally — next `make apply` recreates everything. The DO Project itself is **not** destroyed (intentional; managed in the UI).

### Tear-down checklist

After destroy:

- `make output` should show no droplets.
- DO UI: the `RKE2` project should be empty.
- Local `terraform.tfstate` exists but lists no managed resources.

## Troubleshooting

### `Error: GET ... 401`

Token is missing, expired, or lacks scopes. Re-encrypt with `sops terraform/environments/do-test/secrets.enc.tfvars`.

### `Error: project not found` during plan

Either the project name in `do_project_name` doesn't match a project on this account, or the token lacks `project:read`. Either fix the name, widen the token, or set `do_project_name = null` in `terraform.tfvars`.

### Droplet stuck "new" forever

DO occasionally fails first-boot. Check the DO console (web UI) for cloud-init logs (Droplets → droplet → Console). Common causes: invalid `user_data` (test template rendering with `tofu console`), bad image slug for the region.

### Re-roll a single droplet

```bash
tofu -chdir=environments/do-test taint 'module.infra.digitalocean_droplet.cp[0]'
make plan
make apply
```

The firewall and VPC stay; the one droplet recreates with fresh cloud-init.

### Token rotation

```bash
sops terraform/environments/do-test/secrets.enc.tfvars
# Replace do_token value, save, exit.
make plan       # confirm new token works
```

No re-apply needed unless you also revoked the old token. Revoke the old one in the DO UI after the new one is confirmed working.

## Cost notes

List-price approximations (verify in DO UI for current pricing):

- `s-2vcpu-4gb` ≈ $24/mo per droplet
- `s-4vcpu-8gb` ≈ $48/mo per droplet
- VPC, firewall, SSH key, Project: free

3 CP + 3 worker always-on ≈ $216/mo. Hourly billing applies — `make destroy` between sessions to control burn.

## See also

- [`docs/runbooks/secrets.md`](secrets.md) — SOPS operator setup, key rotation, safe-staging checklist.
- [`docs/diagrams/do-network.md`](../diagrams/do-network.md) — Mermaid of VPC, firewall, droplet placement.
- [`openspec/changes/add-do-droplet-module/`](../../openspec/changes/add-do-droplet-module/) — proposal/design/tasks for this work.
