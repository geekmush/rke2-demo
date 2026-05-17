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

# Branch-safety check. Refuse to continue if the local git branch doesn't
# match the branch Flux's flux-system GitRepository tracks. Otherwise this
# script's self-correcting commits (the project1-dev sed-rename below,
# *.decrypted re-encryption, gotk-sync.yaml decryption-block recovery,
# app_list updates) get pushed to the wrong branch and Flux never sees them.
#
# Bites hard on feature-branch test runs: bootstrap pushes to the tracked
# branch (default main), local recovery commits push to the feature branch,
# Flux watches main, child Kustomizations fail to decrypt SOPS secrets. See
# issue #32 for the original failure case (2026-05-17 unattended test of
# feat/install-do-ccm). When in doubt, merge your feature branch to the
# tracked branch first OR check it out locally before running deploy.sh.
#
# Skipped on the very first bootstrap (gotk-sync.yaml is a single-line
# placeholder shipped by the upstream template; bootstrap will overwrite it).
if [[ -s flux/flux-system/gotk-sync.yaml && "$(cat flux/flux-system/gotk-sync.yaml | wc -l)" -gt 1 ]]; then
  flux_branch=$(yq 'select(.kind == "GitRepository") | .spec.ref.branch' flux/flux-system/gotk-sync.yaml 2>/dev/null)
  [[ "${flux_branch}" == "null" ]] && flux_branch=""
  current_branch=$(git branch --show-current)
  if [[ -n "${flux_branch}" && "${current_branch}" != "${flux_branch}" ]]; then
    cat >&2 <<EOM
ERROR: deploy.sh is running on git branch '${current_branch:-<DETACHED HEAD>}',
but Flux's flux-system GitRepository tracks branch '${flux_branch}'. The
self-correcting commits this script makes would land on
'${current_branch:-<DETACHED HEAD>}' -- where Flux can't see them -- and the
cluster will end up missing the SOPS decryption block, broken app_list
entries, or unencrypted scratch secrets in git.

To validate a feature branch end-to-end, merge it to '${flux_branch}' first
(the PR can stay open) OR check out '${flux_branch}' locally before re-running.

Pass DEPLOY_ALLOW_BRANCH_MISMATCH=1 to suppress this check -- you are
responsible for the consequences.
EOM
    [[ "${DEPLOY_ALLOW_BRANCH_MISMATCH:-}" == "1" ]] || exit 1
    echo "WARNING: DEPLOY_ALLOW_BRANCH_MISMATCH=1 -- continuing anyway." >&2
  fi
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

# Get sops-age + the gotk-sync.yaml decryption block into a consistent state.
#
# Background (issue #24 + #37):
#
#   `flux bootstrap` regenerates gotk-sync.yaml WITHOUT a decryption block. In
#   that state, when kustomize-controller reconciles the flux-system
#   Kustomization, it applies the SOPS-wrapped Secret manifest literally,
#   writing the ENC[...] ciphertext into the cluster's sops-age Secret. If we
#   `kubectl apply` the plaintext over it, the controller's NEXT reconcile
#   overwrites our plaintext with the ciphertext again -- cluster wedges with
#   "failed to import 'age.agekey' data from sops decryption Secret
#   'flux-system/sops-age': failed to parse and add to age identities: unknown
#   identity type" across every Kustomization.
#
#   #28 attempted to fix this by reordering "decryption-block push first, then
#   plaintext apply." That fix turned out to be insufficient (test #3
#   re-demonstrated the race):
#     - When the operator's local gotk-sync.yaml already has the block (from a
#       prior cycle), yq is a no-op, the conditional commit is skipped, the
#       block never reaches main. Adding `--cached` to the diff check below
#       closes that hole.
#     - Even with the block on main, between push and reconcile the controller
#       can race -- it has already-stale Kustomization spec without decryption
#       OR it applies the SOPS-wrapped manifest before reading the new
#       decryption block. Suspend/resume eliminates the race window.
#
# Robust order (this block):
#   1. Suspend the flux-system Kustomization (controller stops reconciling).
#   2. Add the decryption block locally + commit + push UNCONDITIONALLY.
#   3. Apply the plaintext sops-age Secret to the cluster.
#   4. Resume the Kustomization -- controller now has both halves in place.
#   5. Force-reconcile to avoid waiting for the 10-min retry interval.
#
# Steps 1 + 4 are no-ops if the Kustomization doesn't exist yet (first-ever
# bootstrap of an empty cluster). Skipped silently in that case.

if kubectl -n flux-system get kustomization flux-system >/dev/null 2>&1; then
  flux suspend kustomization flux-system
  suspended_flux_system=true
else
  suspended_flux_system=false
fi

yq -i '(select(.kind == "Kustomization") | .spec.decryption) = {"provider": "sops", "secretRef": {"name": "sops-age"}}' flux/flux-system/gotk-sync.yaml

git add flux/flux-system/gotk-sync.yaml
# `--cached` compares the index (post-add) to HEAD, not working tree to HEAD.
# Needed when yq's local edit is a no-op (file already had the block in the
# operator's checkout) but main is stale because `flux bootstrap` pushed a
# regenerated version directly to main from its temp clone, bypassing the
# operator's working tree. See issue #37.
if ! git diff --cached --quiet; then
  git commit -nm "Adding decryption to gotk-sync.yaml"
  git push
fi

# Also update the IN-CLUSTER Kustomization spec directly while suspended.
# Pushing to git alone is not enough (issue #47): when kustomize-controller
# resumes, its first reconcile reads its own spec from the live CR (NOT from
# git) to decide whether to decrypt manifests. If that live spec doesn't have
# .spec.decryption yet, the first reconcile applies sops-age.secrets.yaml
# from git as ciphertext, overwriting our plaintext apply below. Subsequent
# reconciles then see the in-cluster Secret as ciphertext and can't use it
# as a decryption key -- hard-fail with "unknown identity type" cascading
# to every child Kustomization.
#
# kubectl apply -f on the live CR updates the spec atomically while the
# controller is suspended, so the very first post-resume reconcile uses
# the decryption-aware spec.
#
# Gated on suspended_flux_system because on first-ever bootstrap the
# Kustomization CR doesn't exist yet -- nothing to update.
if $suspended_flux_system; then
  kubectl apply -f flux/flux-system/gotk-sync.yaml
fi

# Apply the plaintext sops-age Secret to the cluster. With flux-system
# suspended, the kustomize-controller cannot race-overwrite this. Always
# run -- the in-cluster Secret may be missing OR may be the SOPS ciphertext
# from a prior unsuspended reconcile cycle.
sops -d flux/flux-system/sops-age.secrets.yaml | kubectl apply -f -

if $suspended_flux_system; then
  flux resume kustomization flux-system
fi

# Force-reconcile so the Kustomization picks up both halves immediately
# instead of waiting for the 10-minute retry interval.
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
    # do-ccm: DigitalOcean Cloud Controller Manager. Provides Service
    #   type=LoadBalancer provisioning + node-side cloud integration.
    #   Requires `rke2_cloud_provider_name: external` to be set in
    #   ansible/inventory/group_vars/all/main.yml (it is, by default)
    #   so RKE2 doesn't set its own providerID first -- see
    #   openspec/changes/install-do-ccm/ proposal v3 for the full why.
    #
    # longhorn: distributed block storage. Not yet enabled at this
    #   commit -- restored as part of openspec/changes/enable-longhorn
    #   once that lands (its Group-1 PR is the appropriate place to add
    #   "longhorn.yaml" to this list).
    app_list="digitalocean-cloud-controller-manager.yaml"
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
