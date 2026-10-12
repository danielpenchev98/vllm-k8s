#!/usr/bin/env bash
# Benchmarks one vLLM config through LiteLLM, like a real client. Assumes the infra and the stack are
# deployed (infra/local/setup-infra.sh + deploy/deploy.sh); the only thing it changes is vLLM's config:
#   1. merges the experiment's overrides into deploy/components/vllm/vllm-config.yaml, applies the
#      result as ConfigMap vllm-config-bench-<hash> and points the vllm Deployment at it
#      (a changed config restarts vLLM; an unchanged one is reused)
#   2. checks vLLM's startup log shows the experiment's values
#   3. runs vllm_bench.py through LiteLLM and records vLLM's preemptions during the run
#
#   bench/run.sh bench/experiments/baseline.yaml base-r4 --rate 4 --seed 4
#   for r in 1 2 4 8; do bench/run.sh bench/experiments/seqs-16.yaml seqs16-r$r --rate $r --seed $r; done
#   .venv/bin/python bench/vllm_bench.py --summarize bench/results/*.json
#
# Args after the label go to vllm_bench.py. A reused vLLM still has the previous run's prompts in its
# prefix cache, so give every run its own --seed, or set FRESH=1 to restart vLLM anyway.
#
# Writes results/<label>.json and results/<label>.vllm-config.yaml (the config vLLM ran with).
# vLLM keeps the last experiment's config. Back to the committed one, then drop the bench ConfigMaps:
#   kubectl apply -k deploy/overlays/local-kind && kubectl -n llm rollout status deploy/vllm
#   kubectl -n llm delete configmap -l app.kubernetes.io/part-of=vllm-bench
set -euo pipefail

usage="usage: $0 EXPERIMENT.yaml LABEL [vllm_bench.py args...]"
# Resolved before the cd below, so the path may be relative to where the script was called from.
EXPERIMENT="$(realpath -m "${1:?${usage}}")"
LABEL="${2:?${usage}}"
shift 2
cd "$(dirname "$0")"

NAMESPACE=llm
PYTHON="${PYTHON:-../.venv/bin/python}"
BASE_CONFIG=../deploy/components/vllm/vllm-config.yaml
RESULTS=results
FRESH="${FRESH:-0}"
# The startup probe allows 10 min; leave room for scheduling.
ROLLOUT_TIMEOUT_S="${ROLLOUT_TIMEOUT_S:-900}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Sums a counter from vLLM's /metrics (read from inside the pod; the NetworkPolicy keeps us out).
vllm_metric() {
  kubectl -n "${NAMESPACE}" exec deploy/vllm -- python3 -c \
    'import urllib.request; print(urllib.request.urlopen("http://localhost:8000/metrics").read().decode())' \
    | awk -v m="$1" '$1 ~ "^" m "({|$)" {s += $NF} END {print s + 0}'
}

# Waits for the vllm rollout, but gives up early when the new config makes vLLM crash
# (unknown key, bad value), instead of waiting out the whole timeout.
wait_for_vllm() {
  local deadline=$((SECONDS + ROLLOUT_TIMEOUT_S))
  until kubectl -n "${NAMESPACE}" rollout status deploy/vllm --timeout=10s >/dev/null 2>&1; do
    # Pods being deleted (the previous config's) are skipped.
    if kubectl -n "${NAMESPACE}" get pods -l app=vllm -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{range .status.containerStatuses}}{{with .state.waiting}}{{.reason}} {{end}}{{end}}{{end}}{{end}}' \
        | grep -q CrashLoopBackOff; then
      kubectl -n "${NAMESPACE}" logs -l app=vllm --previous --tail=15 >&2 || true
      die "vLLM crashes with this config (log above); fix ${EXPERIMENT} or restore the committed config"
    fi
    (( SECONDS < deadline )) || die "vLLM not ready after ${ROLLOUT_TIMEOUT_S}s (kubectl -n ${NAMESPACE} get pods -l app=vllm)"
  done
}

wait_for_litellm() {
  local i
  for i in $(seq 30); do
    curl -sf -m 30 http://127.0.0.1:8080/v1/chat/completions -H 'Host: api.localhost' \
      -H 'Content-Type: application/json' \
      -d '{"model":"qwen3-4b","messages":[{"role":"user","content":"hi /no_think"}],"max_tokens":4}' \
      -o /dev/null && return
    sleep 2
  done
  die "no answer from LiteLLM at api.localhost:8080 (is the stack deployed?)"
}

[[ -f "${EXPERIMENT}" ]] || die "experiment file ${EXPERIMENT} not found"
[[ -x "${PYTHON}" ]] || die "${PYTHON} not found (run 'uv sync' in the repo root, or set PYTHON=)"
[[ -f prompts.json ]] || die "bench/prompts.json missing, generate it with: ${PYTHON} gen_prompts.py"

log "Deploying $(basename "${EXPERIMENT}")"
cm="$("${PYTHON}" vllm_config.py render "${BASE_CONFIG}" "${EXPERIMENT}" | kubectl -n "${NAMESPACE}" apply -f - -o name)"
cm="${cm#configmap/}"
current="$(kubectl -n "${NAMESPACE}" get deploy vllm \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')"
if [[ "${current}" != "${cm}" ]]; then
  echo "config ${current} -> ${cm}, restarting vLLM"
  kubectl -n "${NAMESPACE}" patch deploy vllm --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"volumes\":[{\"name\":\"config\",\"configMap\":{\"name\":\"${cm}\"}}]}}}}" >/dev/null
elif [[ "${FRESH}" == 1 ]]; then
  echo "vLLM already runs ${cm}, restarting it (FRESH=1)"
  kubectl -n "${NAMESPACE}" rollout restart deploy/vllm >/dev/null
else
  echo "vLLM already runs ${cm}, reusing it"
fi
wait_for_vllm

log "Checking vLLM runs with the experiment's values"
kubectl -n "${NAMESPACE}" logs deploy/vllm --tail=-1 | "${PYTHON}" vllm_config.py verify "${EXPERIMENT}"
wait_for_litellm

mkdir -p "${RESULTS}"
# Snapshot of what is being measured, so a result can't be mixed up with another config.
{
  echo "# experiment: ${EXPERIMENT}"
  echo "# configmap: ${cm}"
  echo "# args: $(kubectl -n "${NAMESPACE}" get deploy vllm -o jsonpath='{.spec.template.spec.containers[0].args}')"
  kubectl -n "${NAMESPACE}" get configmap "${cm}" -o jsonpath='{.data.config\.yaml}'
} > "${RESULTS}/${LABEL}.vllm-config.yaml"
# How many max-model-len requests the KV cache holds in the worst case.
kubectl -n "${NAMESPACE}" logs deploy/vllm --tail=-1 | grep -E "KV cache size|Maximum concurrency" || true

log "Benchmark ${LABEL}"
# A reused vLLM keeps counting, so report the difference.
preempt_before="$(vllm_metric vllm:num_preemptions_total)"
"${PYTHON}" vllm_bench.py --label "${LABEL}" --out "${RESULTS}/${LABEL}.json" "$@"
preempt_after="$(vllm_metric vllm:num_preemptions_total)"

"${PYTHON}" -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["preemptions"] = float(sys.argv[2]) - float(sys.argv[3]); d["experiment"] = sys.argv[4]; json.dump(d, open(p, "w"), indent=2)' \
  "${RESULTS}/${LABEL}.json" "${preempt_after}" "${preempt_before}" "$(basename "${EXPERIMENT}")"
echo "preemptions during run: $(( ${preempt_after%.*} - ${preempt_before%.*} ))"
echo "vLLM keeps running ${cm}; back to the committed config: kubectl apply -k deploy/overlays/local-kind"
