# Shared settings + helpers for setup-infra.sh and teardown-infra.sh (sourced, not run).

# Space-separated ufw port specs (ranges use ":", e.g. 30000:32767/tcp) to allow inbound: apiserver, flannel VXLAN, kubelet.
K3S_ALLOWED_PORTS="${K3S_ALLOWED_PORTS:-6443/tcp 8472/udp 10250/tcp}"
# Default k3s pod / service CIDRs; must match --cluster-cidr / --service-cidr if overridden.
K3S_POD_CIDR="${K3S_POD_CIDR:-10.42.0.0/16}"
K3S_SERVICE_CIDR="${K3S_SERVICE_CIDR:-10.43.0.0/16}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.1}"
AGENT_IMAGE="${AGENT_IMAGE:-24.04}"
CUDA_TEST_IMAGE="${CUDA_TEST_IMAGE:-nvidia/cuda:13.0.1-base-ubuntu24.04}"
AGENT_NAME="${AGENT_NAME:-k3s-agent}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Under sudo, helm finds no ~/.kube/config and multipass rejects root's unauthenticated client;
# the scripts call sudo themselves where needed.
if [[ ${EUID} -eq 0 ]]; then
  echo "Run as your normal user, not root/sudo." >&2
  exit 1
fi

log() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
gpu_node() { kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}'; }
