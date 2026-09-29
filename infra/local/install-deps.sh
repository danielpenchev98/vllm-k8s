#!/usr/bin/env bash
# Installs local dependencies for running vLLM on k8s with an NVIDIA GPU:
#   - NVIDIA Container Toolkit (+ registers the nvidia runtime with Docker)
#   - kubectl, helm, k9s, uv
#   - k3s server (cluster setup lives in setup-infra.sh)
# Safe to re-run: tools already present are skipped.
set -euo pipefail

NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.20.1-1}"
ARCH="amd64"
K3S_VERSION="${K3S_VERSION:-v1.36.4+k3s1}"

log() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

install_nvidia_container_toolkit() {
  log "NVIDIA Container Toolkit ${NVIDIA_CONTAINER_TOOLKIT_VERSION}"

  sudo apt-get update
  sudo apt-get install -y --no-install-recommends ca-certificates curl gnupg2

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null

  sudo sed -i -e '/experimental/ s/^#//g' /etc/apt/sources.list.d/nvidia-container-toolkit.list

  sudo apt-get update
  sudo apt-get install -y \
    nvidia-container-toolkit="${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
    nvidia-container-toolkit-base="${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
    libnvidia-container-tools="${NVIDIA_CONTAINER_TOOLKIT_VERSION}" \
    libnvidia-container1="${NVIDIA_CONTAINER_TOOLKIT_VERSION}"

  log "Registering nvidia runtime with Docker"
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker
}

install_kubectl() {
  if have kubectl; then log "kubectl already installed, skipping"; return; fi
  log "kubectl"
  local tmp version
  tmp="$(mktemp -d)"
  version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o "${tmp}/kubectl" "https://dl.k8s.io/release/${version}/bin/linux/${ARCH}/kubectl"
  curl -fsSL -o "${tmp}/kubectl.sha256" "https://dl.k8s.io/release/${version}/bin/linux/${ARCH}/kubectl.sha256"
  echo "$(cat "${tmp}/kubectl.sha256")  ${tmp}/kubectl" | sha256sum --check
  sudo install -o root -g root -m 0755 "${tmp}/kubectl" /usr/local/bin/kubectl
  rm -rf "${tmp}"
}

install_helm() {
  if have helm; then log "helm already installed, skipping"; return; fi
  log "helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash
}

install_k9s() {
  if have k9s; then log "k9s already installed, skipping"; return; fi
  log "k9s"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "${tmp}/k9s.deb" "https://github.com/derailed/k9s/releases/latest/download/k9s_linux_${ARCH}.deb"
  chmod 755 "${tmp}"
  chmod 644 "${tmp}/k9s.deb"
  sudo apt-get install -y "${tmp}/k9s.deb"
  rm -rf "${tmp}"
}

install_uv() {
  if have uv; then log "uv already installed, skipping"; return; fi
  log "uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
}

install_k3s() {
  if have k3s; then log "k3s already installed, skipping"; return; fi
  log "k3s ${K3S_VERSION}"
  # Installed after the NVIDIA Container Toolkit so k3s's containerd auto-detects the nvidia runtime.
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -

  if [[ -f "${HOME}/.kube/config" ]]; then
    log "~/.kube/config already exists, leaving it alone (k3s config: /etc/rancher/k3s/k3s.yaml)"
  else
    log "Writing kubeconfig to ~/.kube/config"
    mkdir -p "${HOME}/.kube"
    sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
  fi
}


install_multipass() {
  if ! have snap; then log "snap not installed, skipping multipass"; return; fi
  sudo snap install multipass
}

verify() {
  log "Verifying"
  nvidia-ctk --version | head -1
  kubectl version --client
  helm version --short
  k9s version --short
  uv --version
  k3s --version | head -1
  kubectl get nodes
  docker run --rm --gpus all nvidia/cuda:13.0.1-base-ubuntu24.04 nvidia-smi -L
  multipass version
}

main() {
  install_nvidia_container_toolkit
  install_kubectl
  install_helm
  install_k9s
  install_uv
  install_k3s
  verify
}

main "$@"
