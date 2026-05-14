# Secrets management runbook

This repo encrypts secrets with [SOPS](https://github.com/getsops/sops) using **age** keys. Per groundrule #9, **no plaintext secret ever lands in git** — encrypted files use the `*.enc.<ext>` convention and live next to what they configure (e.g. `terraform/secrets.enc.tfvars`, `ansible/group_vars/all/secrets.enc.yaml`). Encryption rules are in [`.sops.yaml`](../../.sops.yaml).

## One-time operator setup

### 1. Install the toolchain

**Windows (per-user, no admin):**
```powershell
winget install --id FiloSottile.age --scope user --silent --accept-source-agreements --accept-package-agreements
winget install --id Mozilla.SOPS    --scope user --silent --accept-source-agreements --accept-package-agreements
```

**Linux:**
```bash
# Debian/Ubuntu
sudo apt-get install age
# sops: grab the latest release from https://github.com/getsops/sops/releases
```

**macOS:**
```bash
brew install age sops
```

Verify:
```bash
age --version
sops --version
```

### 2. Generate your age keypair

SOPS looks for keys at the default platform path. Generate there:

**Windows:**
```powershell
New-Item -ItemType Directory -Force "$env:APPDATA\sops\age" | Out-Null
age-keygen -o "$env:APPDATA\sops\age\keys.txt"
```

**Linux/macOS:**
```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
```

The command prints your **public key** (`age1...`) — that is what you share. The file written to disk contains both the public and **private** key. Never copy that file into the repo, paste it into chat, or share it.

### 3. Back up the private key out-of-band

If you lose `keys.txt`, every encrypted file in the repo becomes unrecoverable. Save a copy to your password manager, hardware token, or offline media. Treat it like an SSH private key.

### 4. Send your public key to a current recipient

A maintainer adds it to [`.sops.yaml`](../../.sops.yaml) and re-encrypts every existing `*.enc.*` file with `sops updatekeys` (see "Add a new operator" below).

## Day-to-day operations

### Encrypt a new file

Name it with the `*.enc.<ext>` suffix and create it in plaintext for editing, then encrypt in place:

```bash
sops --encrypt --in-place path/to/whatever.enc.yaml
```

`.sops.yaml` selects recipients by `path_regex`. The `encrypted_regex` keeps non-sensitive keys (like `apiVersion`, `metadata.name`) plaintext for diffability — only fields matching `data`, `stringData`, or names containing `password|secret|token|key` are encrypted.

### Decrypt for reading

```bash
sops --decrypt path/to/whatever.enc.yaml
```

### Edit in place (decrypt → editor → re-encrypt automatically)

```bash
sops path/to/whatever.enc.yaml
```

Uses `$EDITOR` (default `vi`). Writes back encrypted on save.

### Use a SOPS-encrypted value from a tool

- **OpenTofu:** consume via `sops --decrypt` in a CI step or local wrapper, never read the encrypted file directly into Tofu. Prefer the [`carlpett/sops` provider](https://registry.terraform.io/providers/carlpett/sops/latest) for in-Tofu decryption.
- **Ansible:** use [`community.sops`](https://galaxy.ansible.com/community/sops) collection — `community.sops.load_vars` or the SOPS vars plugin.
- **Kubernetes manifests under FluxCD:** Flux's [SOPS decryption](https://fluxcd.io/flux/guides/mozilla-sops/) handles encrypted manifests at reconcile time.

## Add a new operator

1. The new operator generates their keypair (steps above) and sends their **public key** to a current recipient.
2. Append it to the `age:` field in [`.sops.yaml`](../../.sops.yaml). The value is a **comma-separated string**, not a YAML list:
   ```yaml
   age: age1exist...,age1newperson...
   ```
3. Re-encrypt every affected file so the new key can decrypt them:
   ```bash
   git ls-files '*.enc.*' | xargs -I{} sops updatekeys -y {}
   ```
   (PowerShell:)
   ```powershell
   git ls-files '*.enc.*' | ForEach-Object { sops updatekeys -y $_ }
   ```
4. Commit `.sops.yaml` plus the touched `*.enc.*` files in one commit.

## Rotate / revoke a compromised key

1. Remove the compromised key from `.sops.yaml`.
2. **Rotate every secret the key could read** — generate fresh database passwords, API tokens, kubeconfigs, etc. Re-encrypting alone does not invalidate values the attacker may have already read.
3. After the values are rotated, re-encrypt:
   ```bash
   git ls-files '*.enc.*' | xargs -I{} sops updatekeys -y {}
   ```
4. Commit. In the commit message, note the rotation and link the incident issue.

## Safe-staging checklist (every commit involving secrets)

- [ ] No plaintext file matching `secrets.*`, `*.tfvars` (other than `*.tfvars.example`), `*.env`, `id_rsa*`, `*.pem`, `kubeconfig`, or `*.age` is staged.
- [ ] Every secret-bearing file is named `*.enc.<ext>` and shows `ENC[AES256_GCM,...]` blobs on inspection.
- [ ] `.sops.yaml` recipients match the intended audience.
- [ ] `age-keygen`'s output file (`keys.txt`) is **not** under the repo working tree.

## References

- SOPS: https://github.com/getsops/sops
- age: https://github.com/FiloSottile/age
- Flux + SOPS: https://fluxcd.io/flux/guides/mozilla-sops/
- `carlpett/sops` Tofu provider: https://registry.terraform.io/providers/carlpett/sops/latest
- `community.sops` Ansible collection: https://galaxy.ansible.com/community/sops
