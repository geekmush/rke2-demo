#!/usr/bin/env bash

export KUBECONFIG="${HOME}/.kube/do-nyc3-rke2-demo"
export cluster_name=do-nyc3-rke2-demo
export flux_path=flux
export git_owner=geekmush
export git_platform=github
export git_repo=do-nyc3-rke2-demo
export k8s_platform=rke2 # rke2, eks, k0s, talos

if [[ "$OSTYPE" == "darwin"* ]]; then
  export sops_dir="${HOME}/Library/Application Support/sops/age"
elif [[ "$OSTYPE" == "linux"* ]]; then
  export sops_dir="${HOME}/.config/sops/age"
fi

# do-nyc3-rke2-demo's age keys.txt is plaintext (per docs/runbooks/linux-workstation-setup.md
# step 8). The upstream template assumes age-passphrase-encrypted keys.txt and uses
# `export SOPS_AGE_KEY=$(age -d ...)` to materialize the key in-shell -- which errors
# on a plaintext file. We use SOPS_AGE_KEY_FILE instead: SOPS reads the file directly
# at decryption time. No bash-level decryption, no passphrase prompt.
# Phase 5 candidate to upstream as a variables.sh switch / both-modes-supported.
export SOPS_AGE_KEY_FILE="${sops_dir}/keys.txt"

# https://github.com/fluxcd/flux2/releases/
export flux_version=2.6.4

# https://dl.k8s.io/release/stable.txt
export kubectl_version=1.34.1

# https://github.com/getsops/sops/releases/
export sops_version=3.10.2

# https://github.com/mikefarah/yq/releases
export yq_version=4.47.2
