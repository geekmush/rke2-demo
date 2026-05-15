#!/usr/bin/env bash
# Operator SSH tunnel for kube API access.
#
# The CP load balancer is INTERNAL (VPC-only), so kubectl on the operator
# workstation can't talk to it directly. This script wraps `autossh` with a
# rotating list of CP hosts so the tunnel survives:
#   - transient network glitches (autossh's job)
#   - a single CP outage (this script's rotation)
#
# Traffic flow:
#   kubectl on operator -> localhost:6443 -> SSH tunnel -> <CP>'s network ->
#     internal LB VPC IP:6443 -> any healthy CP backend -> kube-apiserver
#
# Source of truth for CP IPs and the LB IP is `tofu output -json` -- the
# script reads it on every restart so re-rolls are picked up automatically.
#
# Usage:
#   ansible/scripts/kube-tunnel.sh            # run in foreground
#   ansible/scripts/kube-tunnel.sh --once     # try one CP and exit on failure
#
# In another terminal:
#   export KUBECONFIG="$HOME/.kube/rke2-demo"
#   kubectl get nodes

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.."; pwd)"
tofu_env="$repo_root/terraform/environments/do-test"
ssh_key="${RKE2_SSH_KEY:-$HOME/.ssh/rke2_demo_ed25519}"
local_port="${RKE2_TUNNEL_PORT:-6443}"
known_hosts="${RKE2_KNOWN_HOSTS:-$HOME/.ssh/known_hosts.rke2demo}"

once=false
if [[ "${1:-}" == "--once" ]]; then
  once=true
fi

# --- prereqs ---
command -v tofu     >/dev/null || { echo "tofu not on PATH"     >&2; exit 1; }
command -v jq       >/dev/null || { echo "jq not on PATH"       >&2; exit 1; }
command -v autossh  >/dev/null || { echo "autossh not on PATH -- install with: sudo apt install autossh" >&2; exit 1; }
[[ -r "$ssh_key" ]] || { echo "SSH key not readable: $ssh_key" >&2; exit 1; }

# --- pull current CP IPs + internal LB IP from Tofu ---
read_tofu_state() {
  local tofu_json
  tofu_json="$(tofu -chdir="$tofu_env" output -json)"
  mapfile -t cp_hosts < <(jq -r '.cp_nodes.value[].public_ip' <<<"$tofu_json")
  lb_ip="$(jq -r '.cp_endpoint.value' <<<"$tofu_json")"
  if (( ${#cp_hosts[@]} == 0 )) || [[ -z "$lb_ip" || "$lb_ip" == "null" ]]; then
    echo "Tofu output missing cp_nodes or cp_endpoint -- has \`make -C terraform apply\` run?" >&2
    return 1
  fi
}

# --- main loop ---
read_tofu_state

cat <<MSG
Establishing kube-tunnel.
  local        : 127.0.0.1:$local_port  (point KUBECONFIG's server here)
  internal LB  : $lb_ip:6443             (resolved each restart)
  CP rotation  : ${cp_hosts[*]}
  ssh key      : $ssh_key
Press Ctrl-C to stop.

MSG

trap 'echo; echo "kube-tunnel: shutting down"; exit 0' INT TERM

while true; do
  for host in "${cp_hosts[@]}"; do
    echo "[$(date '+%H:%M:%S')] tunnel via $host -> $lb_ip:6443"
    # autossh -M 0  : monitor port disabled (use SSH's own keepalives instead)
    # -N            : no remote command
    # -L            : local forward
    # ExitOnForwardFailure=yes : exit if the forward can't be set up (LB unreachable)
    set +e
    autossh -M 0 -N \
      -o ServerAliveInterval=10 \
      -o ServerAliveCountMax=2 \
      -o ExitOnForwardFailure=yes \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$known_hosts" \
      -i "$ssh_key" \
      -L "$local_port:$lb_ip:6443" \
      "root@$host"
    rc=$?
    set -e
    echo "[$(date '+%H:%M:%S')] tunnel via $host ended (rc=$rc)"
    if $once; then
      exit "$rc"
    fi
    sleep 2
    # refresh Tofu state each rotation in case droplets were re-rolled
    read_tofu_state || sleep 5
  done
done
