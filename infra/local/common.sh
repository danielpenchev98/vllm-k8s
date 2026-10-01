# Shared settings + helpers for setup-infra.sh and teardown-infra.sh (sourced, not run).

CLUSTER_NAME="${CLUSTER_NAME:-vllm}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.1}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-41.6.1}"
DESCHEDULER_VERSION="${DESCHEDULER_VERSION:-0.36.0}"
CUDA_TEST_IMAGE="${CUDA_TEST_IMAGE:-nvidia/cuda:13.0.1-base-ubuntu24.04}"
# Host folder backing the GPU node's PVCs; must match the extraMounts hostPath in kind-config.yaml.
STORAGE_DIR="${STORAGE_DIR:-/home/kind/storage}"
# Host side of the traefik NodePort mapping in kind-config.yaml (extraPortMappings).
INGRESS_ADDR="${INGRESS_ADDR:-127.0.0.1:8080}"
PROMETHEUS_STACK_VERSION="${PROMETHEUS_STACK_VERSION:-91.8.2}"

# cgroup limits per kind node (docker update). Keep each cpuset to whole physical cores
# (CPU N and N+8 are SMT siblings, see `lscpu -e`), and keep system-reserved in
# kind-config.yaml = host total - these values, or node allocatable won't match.
CPU_NODE_CPUSET="${CPU_NODE_CPUSET:-0,1,8,9}"
CPU_NODE_MEMORY="${CPU_NODE_MEMORY:-8g}"
GPU_NODE_CPUSET="${GPU_NODE_CPUSET:-2-7,10-15}"
GPU_NODE_MEMORY="${GPU_NODE_MEMORY:-48g}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Under sudo, helm and kubectl find no ~/.kube/config and kind would create root-owned clusters;
# the scripts call sudo themselves where needed.
if [[ ${EUID} -eq 0 ]]; then
  echo "Run as your normal user, not root/sudo." >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# `go install` puts nvkind in $(go env GOPATH)/bin, which may not be on PATH in a fresh shell.
if ! have nvkind && have go; then PATH="${PATH}:$(go env GOPATH)/bin"; fi

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; }
# kind node names are also their Docker container names.
node_with() { kubectl get nodes -l "$1" -o jsonpath='{.items[0].metadata.name}'; }
cpu_node() { node_with workload=cpu; }
gpu_node() { node_with workload=gpu-decoder; }
