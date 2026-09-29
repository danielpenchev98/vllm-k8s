#!/usr/bin/env bash
# Sets up the local k3s cluster (run after install-deps.sh):
#   - ufw allowlist for k3s on the host
#   - checks k3s's containerd picked up the host's nvidia runtime
#   - host labeled + tainted workload=gpu-decoder, VM labeled workload=cpu
#   - NVIDIA GPU Operator (driver + toolkit come from the host, not the operator)
#   - nvidia-smi test pod requesting nvidia.com/gpu: 1
#   - multipass VM joined as a CPU-only k3s agent
# Safe to re-run: existing resources are reused.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

configure_firewall() {
  if ! have ufw; then log "ufw not installed, skipping firewall allowlist"; return; fi
  log "ufw allowlist for k3s"
  local port
  for port in ${K3S_ALLOWED_PORTS}; do
    sudo ufw allow "${port}" comment 'k3s'
  done
  sudo ufw allow from "${K3S_POD_CIDR}" to any comment 'k3s pods'
  sudo ufw allow from "${K3S_SERVICE_CIDR}" to any comment 'k3s services'
  if ! sudo ufw status | grep -q '^Status: active'; then
    log "ufw is inactive: rules are saved but not enforced (enable with 'sudo ufw enable', allow SSH first if remote)"
  fi
}

check_nvidia_runtime() {
  log "Checking k3s containerd has the nvidia runtime"
  local config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
  if ! sudo grep -q nvidia-container-runtime "${config}"; then
    # k3s only detects the runtime at startup, e.g. if it was installed before the toolkit.
    log "nvidia runtime missing, restarting k3s"
    sudo systemctl restart k3s
    sudo grep -q nvidia-container-runtime "${config}" \
      || { echo "nvidia runtime still not in ${config}" >&2; exit 1; }
  fi
  sudo grep -n nvidia-container-runtime "${config}"
  kubectl wait --for=create runtimeclass/nvidia --timeout=60s
}

label_gpu_node() {
  local node
  node="$(gpu_node)"
  log "Labeling + tainting ${node} workload=gpu-decoder"
  kubectl label node "${node}" workload=gpu-decoder --overwrite
  # Must match the tolerations in gpu-operator-values.yaml.
  kubectl taint nodes "${node}" workload=gpu-decoder:NoSchedule --overwrite
}

install_gpu_operator() {
  log "NVIDIA GPU Operator ${GPU_OPERATOR_VERSION}"
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
  helm repo update nvidia
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    -n gpu-operator --create-namespace \
    --version "${GPU_OPERATOR_VERSION}" \
    -f "${SCRIPT_DIR}/gpu-operator-values.yaml" \
    --wait --timeout 10m

  log "Waiting for the GPU node to advertise nvidia.com/gpu"
  kubectl wait "node/$(gpu_node)" --for=jsonpath='{.status.allocatable.nvidia\.com/gpu}'=1 --timeout=5m
}

test_gpu_pod() {
  log "nvidia-smi test pod"
  kubectl delete pod nvidia-smi --ignore-not-found
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: nvidia-smi
spec:
  restartPolicy: Never
  # k3s defaults to runc; without this the pod gets scheduled but can't see the GPU.
  runtimeClassName: nvidia
  nodeSelector:
    workload: gpu-decoder
  tolerations:
    - {key: workload, operator: Equal, value: gpu-decoder, effect: NoSchedule}
  containers:
    - name: cuda
      image: ${CUDA_TEST_IMAGE}
      command: ["nvidia-smi"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
  kubectl wait pod/nvidia-smi --for=jsonpath='{.status.phase}'=Succeeded --timeout=5m
  kubectl logs nvidia-smi
  kubectl delete pod nvidia-smi
}

launch_agent_vm() {
  if multipass info "${AGENT_NAME}" >/dev/null 2>&1; then log "VM ${AGENT_NAME} already exists, skipping"; return; fi
  log "multipass VM ${AGENT_NAME}"
  multipass launch "${AGENT_IMAGE}" --name "${AGENT_NAME}" --cpus 2 --memory 8G --disk 30G
}

join_agent() {
  if kubectl get node "${AGENT_NAME}" >/dev/null 2>&1; then log "${AGENT_NAME} already joined, skipping"; return; fi
  log "Joining ${AGENT_NAME} as a CPU-only k3s agent"
  local token host_ip version
  token="$(sudo cat /var/lib/rancher/k3s/server/node-token)"
  # The VM's default gateway is the host's IP on the multipass bridge.
  host_ip="$(multipass exec "${AGENT_NAME}" -- ip route | awk '/default/ {print $3}')"
  version="$(k3s --version | awk 'NR==1 {print $3}')"
  multipass exec "${AGENT_NAME}" -- bash -c \
    "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION='${version}' K3S_URL='https://${host_ip}:6443' K3S_TOKEN='${token}' sh -"

  kubectl wait --for=create "node/${AGENT_NAME}" --timeout=2m
  kubectl wait "node/${AGENT_NAME}" --for=condition=Ready --timeout=5m
  kubectl label node "${AGENT_NAME}" workload=cpu --overwrite
}

main() {
  configure_firewall
  check_nvidia_runtime
  label_gpu_node
  install_gpu_operator
  test_gpu_pod
  launch_agent_vm
  join_agent
  kubectl get nodes -o wide
}

main "$@"
