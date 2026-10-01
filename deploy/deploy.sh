#!/usr/bin/env bash
# Deploys the LLM stack onto the cluster built by infra/local/setup-infra.sh:
#   1. preflight: cluster reachable, GPU + CPU nodes labeled and Ready, manifests render
#   2. namespace, secrets and model PVC (the download Job needs them)
#   3. model weights onto the PVC via model-download/ (resumes; fast if already there)
#   4. everything else: vLLM, LiteLLM, Services, Ingress, NetworkPolicy
#   5. waits for the rollouts and sends one chat request through the Ingress
# Usage: deploy/deploy.sh [kustomize-dir]        (default: deploy/overlays/local-k3s)
# Env:   MODEL_ID        HF repo matching `model:` in components/vllm/vllm-config.yaml (default Qwen/Qwen3-4B)
#        MODEL_REVISION  commit SHA to pin (default main)
#        SKIP_DOWNLOAD=1 skip step 3
# Safe to re-run.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-${DEPLOY_DIR}/overlays/local-kind}"
NAMESPACE=llm
MODEL_ID="${MODEL_ID:-Qwen/Qwen3-4B}"
MODEL_REVISION="${MODEL_REVISION:-main}"
SKIP_DOWNLOAD="${SKIP_DOWNLOAD:-0}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
# Top-level value from components/vllm/vllm-config.yaml, e.g. `config_value model` -> /models/qwen3-4b
config_value() { awk -v k="$1:" '$1 == k {print $2; exit}' "${DEPLOY_DIR}/components/vllm/vllm-config.yaml"; }

preflight() {
  log "Preflight"
  kubectl cluster-info >/dev/null 2>&1 || die "cluster unreachable (run as your user, not sudo; check ~/.kube/config)"
  local label
  for label in workload=gpu-decoder workload=cpu; do
    kubectl get nodes -l "${label}" --no-headers 2>/dev/null | awk '$2 == "Ready"' | grep -q . \
      || die "no Ready node labeled ${label} (run infra/local/setup-infra.sh)"
  done
  [[ -n "$(kubectl get nodes -l workload=gpu-decoder -o jsonpath='{.items[*].status.allocatable.nvidia\.com/gpu}')" ]] \
    || die "GPU node advertises no nvidia.com/gpu (GPU Operator not ready?)"
  kubectl kustomize "${TARGET}" >/dev/null || die "${TARGET} does not render (missing *.env file?)"

  # The download writes /models/<name>; vLLM must be pointed at the same folder.
  local model_name
  model_name="$(basename "${MODEL_ID}" | tr '[:upper:].' '[:lower:]-')"
  [[ "$(config_value model)" == "/models/${model_name}" ]] \
    || die "MODEL_ID=${MODEL_ID} downloads to /models/${model_name}, but components/vllm/vllm-config.yaml has model: $(config_value model)"
}

apply_prerequisites() {
  log "Namespace, secrets and model PVC"
  # Only these kinds from the rendered overlay, so vLLM doesn't start before its weights exist.
  kubectl kustomize "${TARGET}" \
    | awk 'BEGIN {RS = "\n---\n"; ORS = "\n---\n"} /(^|\n)kind: (Namespace|Secret|PersistentVolumeClaim)\n/' \
    | kubectl apply -f -
}

download_model() {
  if [[ "${SKIP_DOWNLOAD}" == 1 ]]; then log "SKIP_DOWNLOAD=1, not downloading"; return; fi
  log "Model ${MODEL_ID}@${MODEL_REVISION}"
  "${DEPLOY_DIR}/model-download/download.sh" "${MODEL_ID}" "${MODEL_REVISION}"
}

apply_stack() {
  log "Applying ${TARGET}"
  kubectl apply -k "${TARGET}"
  local deploy
  for deploy in $(kubectl -n "${NAMESPACE}" get deploy -o name); do
    # vLLM's first start pulls a ~22 GB image, hence the long timeout.
    kubectl -n "${NAMESPACE}" rollout status "${deploy}" --timeout=20m
  done
}

smoke_test() {
  log "Smoke test through the Ingress"
  local hosts="" host model i
  # traefik (ServiceLB) listens on every node IP; the order of this list is arbitrary.
  for i in $(seq 30); do
    hosts="127.0.0.1:8080"
    [[ -n "${hosts}" ]] && break
    sleep 2
  done
  [[ -n "${hosts}" ]] || die "Ingress has no address (kubectl -n ${NAMESPACE} get ingress)"
  host="${hosts%% *}"
  model="$(config_value served-model-name)"
  # traefik can need a few seconds to pick up new endpoints.
  for i in $(seq 12); do
    if curl -sf -m 60 "http://${host}/v1/chat/completions" -H 'Content-Type: application/json' \
         -d "{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hi /no_think\"}],\"max_tokens\":20}" \
         -o /dev/null; then
      log "Ready, model \"${model}\" at:"
      for host in ${hosts}; do echo "    http://${host}/v1"; done
      return
    fi
    sleep 5
  done
  die "no successful response from http://${host}/v1/chat/completions"
}

main() {
  preflight
  apply_prerequisites
  download_model
  apply_stack
  smoke_test
}

main "$@"
