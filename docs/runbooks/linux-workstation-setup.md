# Linux workstation setup

How to set up a Linux machine as the primary working environment for this repo. Covers Ubuntu 24.04+ / 25.10. Expected end state: clone the repo, decrypt SOPS-encrypted files, run OpenTofu and Ansible, edit via VS Code Remote-SSH from any client.

> Tested on Ubuntu 25.10. Steps for other distros differ on package names / repo setup only.

## 0. Prereqs

- Linux user with `sudo`.
- `sshd` running, key-based auth working from your client.
- Your GitHub account already configured with an SSH key for this user (verify: `ssh -T git@github.com` greets you by name).

## 1. Install OS-level toolchain

```bash
sudo apt update
sudo apt install -y \
  git curl unzip jq age \
  build-essential ca-certificates gnupg
```

`gh`, `nodejs`, `npm`, `uv` are pre-installed on the reference machine; install them if missing:

```bash
# gh — if not present
sudo apt install -y gh

# Node.js 20 (for OpenSpec via npx) — NodeSource only if system node is too old
# Check first: node --version  (need >= 20)

# uv — Python via uv per groundrule #1
curl -LsSf https://astral.sh/uv/install.sh | sh
# restart shell to pick up ~/.local/bin
```

## 2. Install SOPS

Ubuntu's repos don't currently ship `sops`. Install the latest release deb directly:

```bash
ARCH=$(dpkg --print-architecture)
SOPS_VERSION=$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)
curl -fsSLo /tmp/sops.deb \
  "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops_${SOPS_VERSION#v}_${ARCH}.deb"
sudo dpkg -i /tmp/sops.deb
rm /tmp/sops.deb
sops --version
```

## 3. Install OpenTofu

Official apt repo (`get.opentofu.org`):

```bash
curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh
sudo bash /tmp/install-opentofu.sh --install-method deb
rm /tmp/install-opentofu.sh
tofu --version
```

## 4. Install Ansible (via uv/pipx)

Groundrule #1 is "Python via uv." Use `uv tool` to install Ansible into its own isolated env:

```bash
uv tool install --with ansible-core ansible
uv tool install ansible-lint
ansible --version
ansible-lint --version
```

## 5. Install kubectl + helm

```bash
# kubectl — pinned-to-latest stable
KVER=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
rm /tmp/kubectl
kubectl version --client

# helm — official install script
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## 6. Install Claude Code CLI

```bash
sudo npm install -g @anthropic-ai/claude-code
claude --version
```

First run will prompt for authentication.

## 7. Authenticate `gh`

```bash
gh auth login
# Pick: GitHub.com → SSH → existing SSH key → login with browser, paste one-time code
gh auth status
```

## 8. Bring your SOPS age private key over

The age private key on Windows lives at `%APPDATA%\sops\age\keys.txt`. On Linux SOPS looks for it at `~/.config/sops/age/keys.txt`.

### Option A — scp from Windows (recommended for an existing operator)

From Windows PowerShell:

```powershell
$src = "$env:APPDATA\sops\age\keys.txt"
ssh geekmush@192.168.5.88 'mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age'
scp $src geekmush@192.168.5.88:~/.config/sops/age/keys.txt
ssh geekmush@192.168.5.88 'chmod 600 ~/.config/sops/age/keys.txt'
```

### Option B — generate a NEW Linux key and add it as a second recipient

Cleaner key hygiene (one key per machine; revoke independently). On Linux:

```bash
mkdir -p ~/.config/sops/age && chmod 700 ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
grep '# public key:' ~/.config/sops/age/keys.txt
```

Then add the printed public key to `.sops.yaml`'s `age:` field (comma-separated) on a branch and re-encrypt every `*.enc.*` file with `sops updatekeys`. See [`secrets.md`](secrets.md#add-a-new-operator).

## 9. Clone the repo

```bash
mkdir -p ~/code && cd ~/code
git clone git@github.com:geekmush/rke2-demo.git
cd rke2-demo
```

## 10. Verify the SOPS round-trip

Make sure encryption is actually working before doing real work:

```bash
cd ~/code/rke2-demo
cat > /tmp/smoke.enc.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: smoke-test
stringData:
  password: hunter2
  token: t0k3n-xyz
EOF
# Note: writing to /tmp/ uses a file outside the repo so creation_rules won't match.
# To test creation_rules, copy it into the repo first:
cp /tmp/smoke.enc.yaml ./.smoke.enc.yaml
sops --encrypt --in-place ./.smoke.enc.yaml
grep -q 'ENC\[AES256_GCM' ./.smoke.enc.yaml && echo "encrypt OK"
sops --decrypt ./.smoke.enc.yaml | grep -q 'hunter2' && echo "decrypt OK"
rm -f ./.smoke.enc.yaml /tmp/smoke.enc.yaml
```

Both lines should print `OK`.

## 11. VS Code Remote-SSH (from any client)

On the **client** (Windows / macOS / another Linux):

1. Install VS Code.
2. Install the **Remote - SSH** extension (`ms-vscode-remote.remote-ssh`).
3. `F1` → "Remote-SSH: Connect to Host..." → `geekmush@192.168.5.88`.
4. After connection, install on the remote: **Claude Code** extension and any language extensions you want (Tofu, YAML, Mermaid, Markdown All in One).
5. `File → Open Folder...` → `~/code/rke2-demo`.

VS Code will auto-install a `~/.vscode-server` userland and run all extensions there. Files, terminal, Claude Code — everything runs on the Linux box. Your Windows machine is now just a display.

To launch Claude Code from inside the integrated terminal:

```bash
cd ~/code/rke2-demo
claude
```

## 12. Confirm groundrules still hold

Before doing real work, sanity-check:

```bash
cd ~/code/rke2-demo
# .sops.yaml should list your operator key(s)
cat .sops.yaml
# memory should be readable in-repo
ls .claude/memory/
# git user is who you expect (set per-repo if needed)
git config --get user.email
```

If `user.email` is unset or wrong:

```bash
git config user.name  "Your Name"
git config user.email "you@example.com"
```

Done — you can now develop on Linux.
