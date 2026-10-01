#!/usr/bin/env bash
# Sets up the local kind cluster (run after install-deps.sh):
#   - kind cluster via nvkind from kind-config.yaml: control plane labeled workload=cpu,
#     GPU worker labeled + tainted workload=gpu-decoder with the host's GPU injected
#   - cgroup limits (cpuset + memory) on the node containers
#   - NVIDIA GPU Operator (driver + toolkit come from the host/nvkind, not the operator)
#   - nvidia-smi test pod requesting nvidia.com/gpu: 1
#   - traefik ingress controller on a NodePort mapped to ${INGRESS_ADDR}
# Safe to re-run: an existing cluster is reused, helm releases are upgraded.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

preflight() {
  log "Preflight"
  local tool
  for tool in docker kind nvkind kubectl helm; do
    have "${tool}" || die "${tool} not found (run install-deps.sh)"
  done
  [[ "$(docker info --format '{{.DefaultRuntime}}')" == nvidia ]] \
    || die "Docker's default runtime isn't nvidia; nvkind needs it (run install-deps.sh)"
  # Created by root here so the bind mount doesn't make Docker create it on the fly.
  [[ -d "${STORAGE_DIR}" ]] || sudo mkdir -p "${STORAGE_DIR}"
}

create_cluster() {
  if cluster_exists; then
    log "Cluster ${CLUSTER_NAME} already exists, skipping"
  else
    log "kind cluster ${CLUSTER_NAME}"
    nvkind cluster create --name "${CLUSTER_NAME}" --config-template "${SCRIPT_DIR}/kind-config.yaml"
  fi
  kubectl config use-context "kind-${CLUSTER_NAME}"
  kubectl wait node --all --for=condition=Ready --timeout=5m
}

limit_node_resources() {
  local cpu gpu
  cpu="$(cpu_node)"
  gpu="$(gpu_node)"
  log "cgroup limits: ${cpu} cpuset=${CPU_NODE_CPUSET} mem=${CPU_NODE_MEMORY}, ${gpu} cpuset=${GPU_NODE_CPUSET} mem=${GPU_NODE_MEMORY}"
  # --memory-swap = --memory: a hard ceiling, no swapping on top of it.
  docker update --cpuset-cpus "${CPU_NODE_CPUSET}" --memory "${CPU_NODE_MEMORY}" --memory-swap "${CPU_NODE_MEMORY}" "${cpu}"
  docker update --cpuset-cpus "${GPU_NODE_CPUSET}" --memory "${GPU_NODE_MEMORY}" --memory-swap "${GPU_NODE_MEMORY}" "${gpu}"
}

check_nodes() {
  local cpu node cpus allocatable
  cpu="$(cpu_node)"
  log "Checking node layout"
  # The control plane doubles as the CPU node; kind may keep its default taint despite `taints: []`.
  kubectl taint node "${cpu}" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
  for node in "${cpu}" "$(gpu_node)"; do
    # nproc respects the cpuset; the kubelet doesn't, it only knows system-reserved.
    cpus="$(docker exec "${node}" nproc)"
    allocatable="$(kubectl get node "${node}" -o jsonpath='{.status.allocatable.cpu}')"
    if [[ "${allocatable}" != "${cpus}" ]]; then
      log "WARNING: ${node} has ${cpus} CPUs but allocatable cpu=${allocatable}; fix system-reserved in kind-config.yaml"
    fi
  done
  kubectl get nodes -L workload -o wide
  kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory'
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
  kubectl wait --for=create runtimeclass/nvidia --timeout=60s
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
  # Without this the pod gets scheduled but runs under runc and can't see the GPU.
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

install_traefik() {
  log "traefik ${TRAEFIK_VERSION}"
  helm repo add traefik https://traefik.github.io/charts --force-update
  helm repo update traefik
  helm upgrade --install traefik traefik/traefik \
    -n traefik --create-namespace \
    --version "${TRAEFIK_VERSION}" \
    -f "${SCRIPT_DIR}/traefik-values.yaml" \
    --wait --timeout 5m

  # Any HTTP status proves the port mapping -> NodePort -> traefik path (404 until deploy.sh adds routes).
  log "Checking traefik answers on ${INGRESS_ADDR}"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "http://${INGRESS_ADDR}/" || true)"
  [[ "${code}" != 000 ]] || die "nothing answers on http://${INGRESS_ADDR}/ (kind-config.yaml extraPortMappings?)"
  echo "    HTTP ${code}"
}

main() {
  preflight
  create_cluster
  limit_node_resources
  check_nodes
  install_gpu_operator
  test_gpu_pod
  install_traefik
  log "Cluster ready. Next: deploy/deploy.sh deploy/overlays/local-kind"
}

main "$@"
