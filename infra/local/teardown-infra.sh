#!/usr/bin/env bash
# Undoes setup-infra.sh, leaving the host k3s server and install-deps.sh tools in place:
#   - CPU agent VM removed from the cluster and deleted
#   - NVIDIA GPU Operator release, its CRDs and namespace
#   - workload label/taint and NFD/GPU feature labels on the host node
#   - ufw allowlist for k3s
# Safe to re-run: anything already gone is skipped. Rebuild with setup-infra.sh.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

remove_agent() {
  log "Removing agent ${AGENT_NAME}"
  kubectl delete node "${AGENT_NAME}" --ignore-not-found
  if multipass info "${AGENT_NAME}" >/dev/null 2>&1; then
    multipass delete --purge "${AGENT_NAME}"
  else
    log "VM ${AGENT_NAME} not found, skipping"
  fi
}

uninstall_gpu_operator() {
  log "Uninstalling NVIDIA GPU Operator"
  kubectl delete pod nvidia-smi --ignore-not-found
  if helm -n gpu-operator status gpu-operator >/dev/null 2>&1; then
    helm -n gpu-operator uninstall gpu-operator --wait --timeout 5m
  fi
  # Pods on a node whose kubelet is gone never finish terminating and would hang the namespace delete.
  if kubectl get namespace gpu-operator >/dev/null 2>&1; then
    kubectl -n gpu-operator delete pod --all --force --grace-period=0
  fi
  # helm uninstall keeps CRDs (chart has cleanupCRD: false); covers *.nvidia.com and NFD's CRDs.
  local crds
  crds="$(kubectl get crd -o name | grep -E '\.nvidia\.com$|\.nfd\.k8s-sigs\.io$' || true)"
  if [[ -n "${crds}" ]]; then
    # shellcheck disable=SC2086
    kubectl delete ${crds}
  fi
  kubectl delete namespace gpu-operator --ignore-not-found
}

reset_gpu_node() {
  local node labels
  node="$(gpu_node)"
  log "Removing workload label/taint and NFD/GPU labels from ${node}"
  kubectl taint nodes "${node}" workload=gpu-decoder:NoSchedule- 2>/dev/null || true
  labels="$(kubectl get node "${node}" -o go-template='{{range $k, $v := .metadata.labels}}{{$k}}{{"\n"}}{{end}}' \
    | grep -E '^(feature\.node\.kubernetes\.io|nvidia\.com)/' | sed 's/$/-/' || true)"
  # shellcheck disable=SC2086
  kubectl label node "${node}" workload- ${labels}
}

remove_firewall_rules() {
  if ! have ufw; then log "ufw not installed, skipping firewall cleanup"; return; fi
  log "Removing ufw allowlist for k3s"
  # "|| true": a rule that is already gone must not abort a re-run.
  local port
  for port in ${K3S_ALLOWED_PORTS}; do
    sudo ufw delete allow "${port}" || true
  done
  sudo ufw delete allow from "${K3S_POD_CIDR}" to any || true
  sudo ufw delete allow from "${K3S_SERVICE_CIDR}" to any || true
}

main() {
  remove_agent
  uninstall_gpu_operator
  reset_gpu_node
  remove_firewall_rules
  kubectl get nodes --show-labels
}

main "$@"
