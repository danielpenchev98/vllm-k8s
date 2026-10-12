#!/usr/bin/env bash
# Benchmarks whatever is deployed right now, through LiteLLM like a real client. Assumes the infra
# and the stack are up (infra/local/setup-infra.sh + deploy/deploy.sh); it never changes them.
#
# To compare scheduler settings (max-num-seqs, max-num-batched-tokens, ...): edit
# deploy/components/vllm/vllm-config.yaml, `kubectl apply -k deploy/overlays/local-kind`, wait for
# the rollout, then run this once per config with a new label.
#
#   bench/run.sh seqs-16                              # defaults of vllm_bench.py
#   bench/run.sh chunked-1024 --rate 8 --no-reasoning # extra args go to vllm_bench.py
#   .venv/bin/python bench/vllm_bench.py --summarize bench/results/*.json
#
# Writes results/<label>.json (with vLLM's preemptions during the run) and
# results/<label>.vllm-config.yaml (the config and args vLLM was running with).
set -euo pipefail
cd "$(dirname "$0")"

LABEL="${1:?usage: $0 LABEL [vllm_bench.py args...]}"
shift
NAMESPACE=llm
PYTHON="${PYTHON:-../.venv/bin/python}"
RESULTS=results

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Sums a counter from vLLM's /metrics (read from inside the pod; the NetworkPolicy keeps us out).
vllm_metric() {
  kubectl -n "${NAMESPACE}" exec deploy/vllm -- python3 -c \
    'import urllib.request; print(urllib.request.urlopen("http://localhost:8000/metrics").read().decode())' \
    | awk -v m="$1" '$1 ~ "^" m "({|$)" {s += $NF} END {print s + 0}'
}

[[ -x "${PYTHON}" ]] || die "${PYTHON} not found (run 'uv sync' in the repo root, or set PYTHON=)"
[[ -f prompts.json ]] || die "bench/prompts.json missing, generate it with: ${PYTHON} gen_prompts.py"
kubectl -n "${NAMESPACE}" rollout status deploy/vllm --timeout=10s >/dev/null 2>&1 \
  || die "vllm Deployment isn't fully rolled out (kubectl -n ${NAMESPACE} rollout status deploy/vllm)"
curl -sf -m 60 http://127.0.0.1:8080/v1/chat/completions -H 'Host: api.localhost' \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3-4b","messages":[{"role":"user","content":"hi /no_think"}],"max_tokens":4}' -o /dev/null \
  || die "no answer from LiteLLM at api.localhost:8080 (is the stack deployed?)"

mkdir -p "${RESULTS}"
# Snapshot of what is being measured, so a result can't be mixed up with another config.
configmap="$(kubectl -n "${NAMESPACE}" get deploy vllm \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="config")].configMap.name}')"
{
  echo "# configmap: ${configmap}"
  echo "# args: $(kubectl -n "${NAMESPACE}" get deploy vllm -o jsonpath='{.spec.template.spec.containers[0].args}')"
  kubectl -n "${NAMESPACE}" get configmap "${configmap}" -o jsonpath='{.data.config\.yaml}'
} > "${RESULTS}/${LABEL}.vllm-config.yaml"
# How many max-model-len requests the KV cache holds: the ceiling for max-num-seqs.
kubectl -n "${NAMESPACE}" logs deploy/vllm --tail=-1 | grep -E "KV cache size|Maximum concurrency" || true

# vLLM isn't restarted between runs, so the counter is cumulative: report the difference.
preempt_before="$(vllm_metric vllm:num_preemptions_total)"
"${PYTHON}" vllm_bench.py --label "${LABEL}" --out "${RESULTS}/${LABEL}.json" "$@"
preempt_after="$(vllm_metric vllm:num_preemptions_total)"

"${PYTHON}" -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["preemptions"] = float(sys.argv[2]) - float(sys.argv[3]); json.dump(d, open(p, "w"), indent=2)' \
  "${RESULTS}/${LABEL}.json" "${preempt_after}" "${preempt_before}"
echo "preemptions during run: $(( ${preempt_after%.*} - ${preempt_before%.*} ))"
