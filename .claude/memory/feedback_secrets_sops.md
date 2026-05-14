---
name: Secrets via SOPS, never plaintext in git
description: All secrets in this repo are SOPS-encrypted (age backend) as *.enc.* files colocated with their config. Never commit plaintext credentials, tokens, kubeconfigs, or .tfvars with sensitive values.
type: feedback
---

Secrets management in this repo uses **SOPS with age**. Encrypted files follow the `*.enc.<ext>` convention (`secrets.enc.tfvars`, `secrets.enc.yaml`, etc.) and live colocated with the config they belong to. Encryption rules are in `.sops.yaml` at the repo root. This is groundrule #9 in `CLAUDE.md`.

**Why:** User stated on 2026-05-14: "we want to use SOPS for secrets management. NEVER commit any secrets to git." Production environment also uses Gitea, so secrets handling must be portable.

**How to apply:**
- Before staging anything, scan the diff for tokens, keys, passwords, `.tfvars` with real values, kubeconfigs, age private keys, `.env` files. If anything questionable is staged, stop and confirm with the user.
- Treat unstaged secret-shaped files as sensitive in-progress work — do not delete or commit them.
- When creating new config that needs a secret, generate it as `<thing>.enc.<ext>` from the start; never write a plaintext version intending to encrypt later.
- The `age` keyring is operator-local (`~/.config/sops/age/keys.txt` or `%APPDATA%\sops\age\keys.txt` on Windows). Never read, copy, or print private key material into chat or files.
- The placeholder age recipient in `.sops.yaml` (`age1placeholder...`) is not a real key — replace before encrypting anything real.
