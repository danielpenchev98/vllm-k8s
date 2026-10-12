#!/usr/bin/env bash
# Benchmarks vLLM scheduler settings on the cluster, through LiteLLM like a real client.
# For each config it:
#   1. patches the vllm Deployment's container args (they override components/vllm/vllm-config.yaml)
#      and waits for the Recreate rollout, so every run starts from a fresh pod and fresh counters
#   2. runs vllm_bench.py against LiteLLM (api.localhost:8080)
#   3. saves the vLLM log and vLLM's preemption count next to the result
# The original args are put back on exit, also on Ctrl-C or failure.
#
#   bench/sweep.sh chunk              # max-num-batched-tokens (chunked-prefill budget), max-num-seqs fixed
#   bench/sweep.sh seqs               # max-num-seqs, max-num-batched-tokens fixed
#   RATE=8 bench/sweep.sh seqs        # heavier load
#
# Env: RATE            mean request arrivals per second (default 4)
#      NUM_PROMPTS     requests per run (default 300)
#      MAX_MODEL_LEN   pinned so runs are comparable (default 8192, matches gen_prompts.py)
#      PREFIX_CACHING  0 = off, so the shared system prompt is really prefilled every time (default)
#                      1 = on, like the deployed config
#      SEQS            max-num-seqs held fixed in the chunk sweep (default 16)
#      BATCHED         max-num-batched-tokens held fixed in the seqs sweep (default 2048)
#      BENCH_ARGS      extra vllm_bench.py flags, e.g. "--no-reasoning --max-tokens 512"
set -euo pipefail
cd "$(dirname "$0")"

SWEEP="${1:-}"
NAMESPACE=llm
RATE="${RATE:-4}"
NUM_PROMPTS="${NUM_PROMPTS:-300}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-8192}"
PREFIX_CACHING="${PREFIX_CACHING:-0}"
SEQS="${SEQS:-16}"
BATCHED="${BATCHED:-2048}"
BENCH_ARGS="${BENCH_ARGS:-}"
PYTHON="${PYTHON:-../.venv/bin/python}"
# Startup probe allows 10 min; leave room for scheduling and the image already being cached.
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-15m}"

case "${SWEEP}" in
  chunk)
    labels=(chunked-512 chunked-1024 chunked-2048 chunked-4096 chunked-8192 no-chunking)
    extra_args=(
      "--max-num-seqs ${SEQS} --max-num-batched-tokens 512"
      "--max-num-seqs ${SEQS} --max-num-batched-tokens 1024"
      "--max-num-seqs ${SEQS} --max-num-batched-tokens 2048"
      "--max-num-seqs ${SEQS} --max-num-batched-tokens 4096"
      "--max-num-seqs ${SEQS} --max-num-batched-tokens 8192"
      # Without chunking the budget must fit a whole prompt, i.e. >= max-model-len.
      "--max-num-seqs ${SEQS} --no-enable-chunked-prefill --max-num-batched-tokens ${MAX_MODEL_LEN}"
    )
    ;;
  seqs)
    labels=(seqs-8 seqs-16 seqs-32 seqs-64)
    extra_args=(
      "--max-num-batched-tokens ${BATCHED} --max-num-seqs 8"
      "--max-num-batched-tokens ${BATCHED} --max-num-seqs 16"
      "--max-num-batched-tokens ${BATCHED} --max-num-seqs 32"
      "--max-num-batched-tokens ${BATCHED} --max-num-seqs 64"
    )
    ;;
  *) echo "usage: $0 chunk|seqs" >&2; exit 2 ;;
esac

common_args="--max-model-len ${MAX_MODEL_LEN}"
[[ "${PREFIX_CACHING}" == 1 ]] || common_args+=" --no-enable-prefix-caching"
RESULTS="results/${SWEEP}-rate${RATE}-prefix${PREFIX_CACHING}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# Sums a counter from vLLM's /metrics (read from inside the pod; the NetworkPolicy keeps us out).
vllm_metric() {
  kubectl -n "${NAMESPACE}" exec deploy/vllm -- python3 -c \
    'import urllib.request; print(urllib.request.urlopen("http://localhost:8000/metrics").read().decode())' \
    | awk -v m="$1" '$1 ~ "^" m "({|$)" {s += $NF} END {print s + 0}'
}

# Merge-patches the vllm container args and the bench/config annotation (null removes it).
# The annotation changes on every config, so the pod is recreated even if the args are unchanged.
patch_vllm() {
  local args_json="$1" annotation="$2"
  kubectl -n "${NAMESPACE}" patch deploy vllm --type=strategic -p "{\"spec\":{\"template\":{
    \"metadata\":{\"annotations\":{\"bench/config\":${annotation}}},
    \"spec\":{\"containers\":[{\"name\":\"vllm\",\"args\":${args_json}}]}}}}" >/dev/null
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
  return 1
}

[[ -x "${PYTHON}" ]] || die "${PYTHON} not found (run 'uv sync' in the repo root, or set PYTHON=)"
[[ -f prompts.json ]] || die "bench/prompts.json missing, generate it with: ${PYTHON} gen_prompts.py"

ORIG_ARGS="$(kubectl -n "${NAMESPACE}" get deploy vllm -o jsonpath='{.spec.template.spec.containers[0].args}')"
# A run killed before its cleanup leaves experiment args behind; don't adopt them as the baseline.
if grep -qE 'max-num-seqs|max-num-batched-tokens|max-model-len|chunked-prefill|prefix-caching' <<<"${ORIG_ARGS}"; then
  die "vllm already runs with sweep args ${ORIG_ARGS}; reset it with: kubectl apply -k deploy/overlays/local-kind"
fi

restore() {
  log "Restoring vLLM args ${ORIG_ARGS} (rollout continues in the background)"
  patch_vllm "${ORIG_ARGS}" null || echo "restore failed, run: kubectl apply -k deploy/overlays/local-kind" >&2
}
trap restore EXIT

mkdir -p "${RESULTS}"
done_labels=()
for i in "${!labels[@]}"; do
  label="${labels[$i]}"
  # shellcheck disable=SC2086  # the arg strings are meant to be split into words
  args_json="$("${PYTHON}" -c 'import json, sys; print(json.dumps(json.loads(sys.argv[1]) + sys.argv[2:]))' \
    "${ORIG_ARGS}" ${common_args} ${extra_args[$i]})"
  log "${label}: ${common_args} ${extra_args[$i]}"

  patch_vllm "${args_json}" "\"${label}\""
  if ! kubectl -n "${NAMESPACE}" rollout status deploy/vllm --timeout="${ROLLOUT_TIMEOUT}"; then
    kubectl -n "${NAMESPACE}" logs deploy/vllm --tail=-1 > "${RESULTS}/${label}.log" 2>&1 || true
    echo "vLLM didn't become ready, skipping ${label} (log: ${RESULTS}/${label}.log)" >&2
    continue
  fi
  wait_for_litellm || die "LiteLLM can't reach vLLM after the rollout"
  # How many max-model-len requests the KV cache holds: the ceiling for max-num-seqs.
  kubectl -n "${NAMESPACE}" logs deploy/vllm | grep -E "KV cache size|Maximum concurrency" || true

  # shellcheck disable=SC2086
  "${PYTHON}" vllm_bench.py --label "${label}" --rate "${RATE}" --num-prompts "${NUM_PROMPTS}" \
    --out "${RESULTS}/${label}.json" ${BENCH_ARGS}

  preemptions="$(vllm_metric vllm:num_preemptions_total)"
  "${PYTHON}" -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["preemptions"] = float(sys.argv[2]); d["vllm_args"] = sys.argv[3]; json.dump(d, open(p, "w"), indent=2)' \
    "${RESULTS}/${label}.json" "${preemptions}" "${common_args} ${extra_args[$i]}"
  kubectl -n "${NAMESPACE}" logs deploy/vllm --tail=-1 > "${RESULTS}/${label}.log"
  done_labels+=("${label}")
done

[[ ${#done_labels[@]} -gt 0 ]] || die "no config finished"
echo
"${PYTHON}" vllm_bench.py --summarize $(printf "${RESULTS}/%s.json " "${done_labels[@]}")
