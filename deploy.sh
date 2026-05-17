#!/usr/bin/env bash

# This script is idempotent, fails fast, and should be safe to run against a running cluster. It requires the variables.sh file.

# TODO: Remove x to disable debug output after someone with a Mac tests this script.
# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
set -Eexuo pipefail

# https://stackoverflow.com/questions/59895/how-do-i-get-the-directory-where-a-bash-script-is-located-from-within-the-script
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Need to cd to this dir, because there are a lot of git commands in this script that expect to be run from this directory.
cd "${SCRIPT_DIR}"

# Telling shellcheck to stop whining...
# shellcheck source=/dev/null
source variables.sh

# Set the path for the binaries for the environment running this
OS="$(uname -o | tr '[:upper:]' '[:lower:]' | sed -e 's%^gnu/%%')"
ARCH="$(uname -m | sed -e 's/x86_64/amd64/g')"
BIN_DIR="${SCRIPT_DIR}/bin/${OS}-${ARCH}"
mkdir -p "${BIN_DIR}"
export PATH="${BIN_DIR}:${PATH}"

# Check for "kubectl" runtime or install it
if [[ "$(kubectl version --client=true -o yaml | yq .clientVersion.gitVersion)" != "v${kubectl_version}" ]]; then
  # install packaged binaries for this arch
  curl -sLo "${BIN_DIR}/kubectl" "https://dl.k8s.io/release/v${kubectl_version}/bin/${OS}/${ARCH}/kubectl"
  curl -sLo "${BIN_DIR}/kubectl.sha256" "https://dl.k8s.io/release/v${kubectl_version}/bin/${OS}/${ARCH}/kubectl.sha256"
  cd "${BIN_DIR}"
  echo "$(cat kubectl.sha256) kubectl" | sha256sum --check
  rm -f kubectl.sha256
  chmod ugo+rx kubectl
  cd -
fi

# Check for "sops" runtime or install it
if [[ "$(sops --version | grep -e '^sops' | awk '{print $2}')" != "${sops_version}" ]] ; then
  curl -sLo "${BIN_DIR}/sops-v${sops_version}.checksums.txt" "https://github.com/getsops/sops/releases/download/v${sops_version}/sops-v${sops_version}.checksums.txt"
  curl -sLo "${BIN_DIR}/sops-v${sops_version}.${OS}.${ARCH}" "https://github.com/getsops/sops/releases/download/v${sops_version}/sops-v${sops_version}.${OS}.${ARCH}"
  cd "${BIN_DIR}"
  FILENAME="sops-v${sops_version}.${OS}.${ARCH}"
  sha256sum -c <(grep "${FILENAME}" "sops-v${sops_version}.checksums.txt")
  rm -f "sops-v${sops_version}.checksums.txt"
  mv "${FILENAME}" sops
  chmod ugo+rx sops
  cd -
fi

# Check for "flux" runtime or install it
if [[ "$(flux --version | cut -d' ' -f3)" != "${flux_version}" ]] ; then
  curl -sLo "${BIN_DIR}/flux_${flux_version}_checksums.txt" "https://github.com/fluxcd/flux2/releases/download/v${flux_version}/flux_${flux_version}_checksums.txt"
  curl -sLo "${BIN_DIR}/flux_${flux_version}_${OS}_${ARCH}.tar.gz" "https://github.com/fluxcd/flux2/releases/download/v${flux_version}/flux_${flux_version}_${OS}_${ARCH}.tar.gz"
  cd "${BIN_DIR}"
  FILENAME="flux_${flux_version}_${OS}_${ARCH}.tar.gz"
  sha256sum -c <(grep "${FILENAME}" "flux_${flux_version}_checksums.txt")
  tar xvzf "${FILENAME}"
  rm -f "${FILENAME}" "flux_${flux_version}_checksums.txt"
  cd -
fi

# Check for "yq" runtime or install it
if [[ "$(yq --version | awk '{ print $4 }')" != "v${yq_version}" ]] ; then
  cd "${BIN_DIR}"
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/yq_${OS}_${ARCH}.tar.gz" -O - | tar xz
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/checksums"
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/checksums_hashes_order"
  wget --no-verbose "https://github.com/mikefarah/yq/releases/download/v${yq_version}/extract-checksum.sh"
  chmod +x extract-checksum.sh
  ./extract-checksum.sh SHA-256 "yq_${OS}_${ARCH}" | rhash -c -
  mv "yq_${OS}_${ARCH}" yq
  rm -v checksums checksums_hashes_order extract-checksum.sh
  cd -
fi

# Replace project1-dev with cluster_name in all files except this script.
# Have to use -i.bak because Mac sed is garbage.
#
# --exclude-dir=archive: archived design/decision docs intentionally retain
#   project1-dev as part of their historical record. Sed-replacing those
#   corrupts the record. (Candidate Phase-5 upstream contribution to
#   devopscoop/fluxcd-template -- generic enough to belong upstream.)
# --exclude-dir=openspec: active OpenSpec change proposals reference
#   project1-dev as a literal string when documenting the convention or
#   describing prior renames. Project-specific to this repo (OpenSpec is
#   not part of the upstream template), so this exclusion stays local.
while read -r f; do
  sed -i.bak "s/project1-dev/${cluster_name}/g" "${f}"
  rm "${f}.bak"
  git add "${f}"
done < <(grep -rIl project1-dev --exclude-dir .git --exclude-dir archive --exclude-dir openspec --exclude deploy.sh .)

# This if statement is needed for idempotency. Don't commit and push if there are no changes.
if ! git diff HEAD --quiet; then

  # Using -n so that SOME PEOPLE'S pre-commit hooks don't freak out and break things. Talking about myself here. I have a large collection of hooks.
  git commit -nm "Replacing project1-dev with ${cluster_name}"

  git push
fi

# Decide whether to run `flux bootstrap`.
#
# Two conditions trigger bootstrap:
#   1. Repo has never been bootstrapped: gotk-sync.yaml is the single-line
#      placeholder that ships with this template.
#   2. Repo is bootstrapped from a PRIOR cluster, but THIS cluster is fresh:
#      flux-system manifests are committed, but the cluster has no
#      flux-system namespace yet. Without this check the script would skip
#      bootstrap, then fail later when `kubectl apply` tries to write the
#      sops-age Secret into a namespace that doesn't exist. (See issue #24.)
#
# `flux bootstrap` is itself idempotent against an already-bootstrapped
# cluster + repo, but we avoid the extra GitHub API churn / commit when
# we can.
#
# Using image-reflector-controller and image-automation-controller, because they're dope as heck, son! https://fluxcd.io/flux/guides/image-update/
# --read-write-key is needed by the image-automation-controller
needs_bootstrap=false
if [[ "$(cat flux/flux-system/gotk-sync.yaml | wc -l)" == "1" ]]; then
  needs_bootstrap=true
elif ! kubectl get ns flux-system >/dev/null 2>&1; then
  needs_bootstrap=true
fi
if $needs_bootstrap; then
  case "$git_platform" in
    github)
      flux bootstrap github \
        --components-extra image-reflector-controller,image-automation-controller \
        --owner="${git_owner}" \
        --path="${flux_path}" \
        --read-write-key \
        --repository="${git_repo}"
      ;;
    # https://fluxcd.io/flux/installation/bootstrap/gitlab/
    gitlab)
      flux bootstrap gitlab \
        --components-extra image-reflector-controller,image-automation-controller \
        --owner="${git_owner}" \
        --path="${flux_path}" \
        --read-write-key \
        --repository="${git_repo}"
      ;;
    *)
      echo 'ERROR: Invalid git_platform.' >&2
      exit 1
      ;;
  esac
fi

git pull

# Encrypt all the `*.decrypted` files with your new sops age key:
while read -r f; do
  sops --filename-override "${f//.decrypted}" -e "${f}" > "${f//.decrypted}"
  git add "${f//.decrypted}"
  git rm "${f}"
done < <(find . -name '*.decrypted')
if ! git diff HEAD --quiet; then
  git commit -nm "Encrypting secrets"
  git push
fi

# Add the SOPS decryption block to gotk-sync.yaml BEFORE applying the sops-age
# Secret. Reasoning (see issue #24):
#
#   `flux bootstrap` regenerates gotk-sync.yaml without a decryption block.
#   In that state, when kustomize-controller reconciles the flux-system
#   Kustomization, it applies the SOPS-wrapped Secret manifest literally --
#   writing the ENC[...] ciphertext into the cluster's sops-age Secret. If we
#   then `kubectl apply` the plaintext over it, the controller's next
#   reconcile will overwrite our plaintext with the ciphertext again. The
#   safe order is:
#     1. add decryption block to gotk-sync.yaml + commit + push  (here)
#     2. apply plaintext sops-age Secret                          (next)
#     3. reconcile -- controller now decrypts before applying.
#
# Step 1 may briefly leave the Kustomization stuck on "secret 'sops-age' not
# found" until step 2 runs; that's a transient error, not a data corruption.
yq -i '(select(.kind == "Kustomization") | .spec.decryption) = {"provider": "sops", "secretRef": {"name": "sops-age"}}' flux/flux-system/gotk-sync.yaml

git add flux/flux-system/gotk-sync.yaml
if ! git diff HEAD --quiet; then
  git commit -nm "Adding decryption to gotk-sync.yaml"
  git push
fi

# Apply the SOPS AGE secret to the cluster. With the decryption block now in
# the repo, the next reconcile will decrypt the SOPS-wrapped manifest in git
# and confirm-rather-than-overwrite this plaintext.
sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -

# Force-reconcile so the Kustomization recovers from any prior "secret not
# found" failure in step 1 without waiting for the 10m retry interval.
flux reconcile source git flux-system
flux reconcile kustomization flux-system

# Open the Flux floodgates! Enable everything!
core_app_list="cert-manager-custom-resources.yaml cert-manager.yaml external-dns.yaml imagepolicies.yaml imagerepositories.yaml imageupdateautomation.yaml ingress-nginx.yaml sops-age.secrets.yaml"
case "$k8s_platform" in
  eks)
    app_list="metrics-server.yaml"
    ;;
  k0s)
    app_list="metallb.yaml metallb-custom-resources.yaml rook-ceph.yaml rook-ceph-cluster.yaml"
    ;;
  talos)
    app_list="metallb.yaml metallb-custom-resources.yaml"
    ;;
  rke2)
    # CCM (digitalocean-cloud-controller-manager) is intentionally OFF here
    # while install-do-ccm is reworked. Test #2 on 2026-05-17 found that
    # the v2 design (kubelet --cloud-provider=external alone) is
    # insufficient -- RKE2 sets providerID=rke2://... at first node-join,
    # which is immutable, and CCM refuses to process nodes lacking the
    # digitalocean:// prefix. The fix is RKE2's cloud-provider-name=external
    # in server/agent config and must be in place BEFORE first node-join.
    # That rework lives in openspec/changes/install-do-ccm/ (revision 3,
    # in progress). The vendored CCM manifest + Secret + per-app Flux
    # Kustomization manifest stay in the repo as building blocks; only the
    # wiring (this app_list + flux/flux-system/kustomization.yaml's
    # resources list) is backed out.
    #
    # longhorn: distributed block storage. Not yet enabled at this
    #   commit -- restored as part of openspec/changes/enable-longhorn
    #   once that lands (its Group-1 PR is the appropriate place to add
    #   "longhorn.yaml" to this list).
    app_list=""
    ;;
  *)
    echo "ERROR: k8s_platform invalid" >&2
    exit 1
    ;;
esac
for app in $core_app_list $app_list; do
  yq -i ".resources = (.resources + [\"${app}\"] | unique)" flux/flux-system/kustomization.yaml
done
git add flux/flux-system/kustomization.yaml
if ! git diff HEAD --quiet; then
  git commit -nm "Enabling Flux Kustomizations"
  git push
  flux reconcile source git flux-system
  flux reconcile kustomization flux-system
fi
