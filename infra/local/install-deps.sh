#!/usr/bin/env bash
# Installs local dependencies for running vLLM on a kind cluster with an NVIDIA GPU:
#   - NVIDIA Container Toolkit, set up as Docker's default runtime for nvkind
#   - kind, nvkind, kubectl, helm, k9s, uv
# Needs Docker Engine and Go already installed. Cluster setup lives in setup-infra.sh.
# Safe to re-run: tools already present are skipped.
set -euo pipefail

NVIDIA_CONTAINER_TOOLKIT_VERSION="${NVIDIA_CONTAINER_TOOLKIT_VERSION:-1.20.1-1}"
ARCH="amd64"
KIND_VERSION="${KIND_VERSION:-v0.33.0}"
# nvkind has no release tags; pin the commit (go.mod pseudo-version v0.0.0-20260630043359-c57050497cff).
NVKIND_VERSION="${NVKIND_VERSION:-c57050497cff}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

check_prerequisites() {
  log "Checking prerequisites"
  have docker || die "Docker Engine not found: install it from Docker's apt repo (not the snap)"
  docker info >/dev/null 2>&1 || die "can't talk to Docker: add yourself to the docker group and log in again"
  have go || die "Go not found: nvkind is installed with 'go install' (needs go >= 1.24, older go auto-switches)"
}

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

  # kind node containers can't ask for GPUs with --gpus, so nvkind relies on the nvidia runtime
  # being Docker's default and picking up GPUs from /var/run/nvidia-container-devices mounts.
  log "nvidia as Docker's default runtime, GPUs requestable via volume mounts"
  sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
  sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
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

install_kind() {
  if have kind; then log "kind already installed, skipping"; return; fi
  log "kind ${KIND_VERSION}"
  local tmp url
  tmp="$(mktemp -d)"
  url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}"
  curl -fsSL -o "${tmp}/kind" "${url}"
  curl -fsSL -o "${tmp}/kind.sha256sum" "${url}.sha256sum"
  echo "$(cut -d' ' -f1 "${tmp}/kind.sha256sum")  ${tmp}/kind" | sha256sum --check
  sudo install -o root -g root -m 0755 "${tmp}/kind" /usr/local/bin/kind
  rm -rf "${tmp}"
}

install_nvkind() {
  local bin
  bin="$(go env GOPATH)/bin/nvkind"
  if [[ -x "${bin}" ]]; then log "nvkind already installed, skipping"; return; fi
  log "nvkind @${NVKIND_VERSION}"
  go install "github.com/NVIDIA/nvkind/cmd/nvkind@${NVKIND_VERSION}"
  if ! have nvkind; then
    log "nvkind is in $(go env GOPATH)/bin, which isn't on PATH (the infra scripts add it themselves)"
  fi
}

verify() {
  log "Verifying"
  nvidia-ctk --version | head -1
  kubectl version --client
  helm version --short
  k9s version --short
  uv --version
  kind version
  "$(go env GOPATH)/bin/nvkind" --help >/dev/null && echo "nvkind ok"
  docker info --format 'Docker default runtime: {{.DefaultRuntime}}'
  docker run --rm --gpus all nvidia/cuda:13.0.1-base-ubuntu24.04 nvidia-smi -L
}

main() {
  check_prerequisites
  install_nvidia_container_toolkit
  install_kubectl
  install_helm
  install_k9s
  install_uv
  install_kind
  install_nvkind
  verify
}

main "$@"
